import 'dart:async' show Timer;
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../alarm/alarm_player.dart';
import '../data/nightscout.dart';
import '../logic/faults.dart';
import '../logic/food.dart';
import '../logic/school_lunch.dart';
import '../logic/meal_plan.dart';
import '../logic/profile.dart';
import '../logic/glucose.dart';
import '../ui/alert_screen.dart';
import '../ui/checklist_screen.dart';
import '../ui/meal_plan_screen.dart';
import '../ui/night_screen.dart';
import '../ui/target_screen.dart';
import 'settings.dart';

enum AlarmKind { redLow, yellowLow, predictedLow, yellowHigh, redHigh, noData, loop, reservoir, pumpBattery }

String alarmTitle(AlarmKind k) {
  switch (k) {
    case AlarmKind.redLow:
      return 'Low';
    case AlarmKind.yellowLow:
      return 'Getting low';
    case AlarmKind.predictedLow:
      return 'Low predicted';
    case AlarmKind.yellowHigh:
      return 'Getting high';
    case AlarmKind.redHigh:
      return 'High';
    case AlarmKind.noData:
      return 'No new readings';
    case AlarmKind.loop:
      return 'Loop not running';
    case AlarmKind.reservoir:
      return 'Insulin running low';
    case AlarmKind.pumpBattery:
      return 'Pump battery low';
  }
}

/// Which sound settings (kSoundGroups) an alarm uses.
int soundGroup(AlarmKind k) {
  switch (k) {
    case AlarmKind.redLow:
      return 0;
    case AlarmKind.yellowLow:
    case AlarmKind.predictedLow:
      return 1;
    case AlarmKind.yellowHigh:
      return 2;
    case AlarmKind.redHigh:
      return 3;
    default:
      return 4;
  }
}

bool isRedAlarm(AlarmKind k) => k == AlarmKind.redLow || k == AlarmKind.redHigh;

class ActiveAlarm {
  final AlarmKind kind;
  final DateTime started;
  final bool gentle;
  final bool test;
  ActiveAlarm(this.kind, this.started, {this.gentle = false, this.test = false});
}

/// One-time alert: sound / vibrate / flash once the glucose reaches a value.
class TargetWatch {
  final double mg;
  final bool rising; // true: alert at mg or higher; false: at mg or lower
  final DateTime started;
  final DateTime? expires; // countdown end, null = none
  final bool timeUpAlert; // at the end of the countdown: alert (true) or just cancel
  final bool sound;
  final int soundIndex;
  final int volume;
  final bool vibrate;
  final bool flash;
  final int color;
  TargetWatch({
    required this.mg,
    required this.rising,
    required this.started,
    this.expires,
    this.timeUpAlert = true,
    this.sound = true,
    this.soundIndex = 0,
    this.volume = 80,
    this.vibrate = true,
    this.flash = true,
    this.color = 0xFF3DBE7A,
  });
}

/// A target alert that went off: reached, or countdown over.
class TargetHit {
  final TargetWatch watch;
  final bool reached;
  final double? mg;
  TargetHit(this.watch, this.reached, this.mg);
}

class Snooze {
  final DateTime until;
  final double? level;
  Snooze(this.until, this.level);
}

final AppState app = AppState();

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  SharedPreferences? _prefs;
  Settings settings = Settings.initial();
  final AlarmPlayer player = AlarmPlayer();
  GlobalKey<NavigatorState>? navKey;

  List<Entry> entries = [];
  List<Treatment> treatments = [];
  DeviceInfo? device;
  DateTime? sensorStart;
  DateTime? siteChange;
  DateTime? insulinChange;
  DateTime? pumpBatteryChange;
  String? error;
  /// Therapy profiles from the site, newest first.
  List<ProfileDoc> profiles = [];

  // Food list (Nightscout's api/v1/food), loaded when the Food screen opens.
  List<Food> foods = [];
  bool foodsLoaded = false;
  String? foodsError;
  /// The meal being put together on the Food screen (kept while switching tabs).
  final Meal meal = Meal();
  /// From your own server: why no readings are coming in (shown in a bar).
  String? feedProblem;
  /// Your own server's health report (null on a plain Nightscout).
  Health? health;
  /// Internet check, done only when the site does not answer (null = not checked).
  bool? internetUp;
  DateTime? lastFetch;
  bool loading = false;

  ActiveAlarm? active;
  final Map<AlarmKind, Snooze> snoozes = {};
  bool alertOpen = false;
  TargetWatch? target;
  TargetHit? targetHit;
  bool _targetOpen = false;

  // Meal insulin plan (Food screen): steps that ring when due.
  MealPlan? mealPlan;
  MealStep? dueStep;
  String? dueReason;
  bool _stepOpen = false;
  bool nightOpen = false;
  bool checklistOpen = false;
  String _lastAutoNight = '';
  String _lastChecklist = '';

  Timer? _poll;
  Timer? _tick;
  int _n = 0;

  Future<void> init(GlobalKey<NavigatorState> key) async {
    navKey = key;
    _prefs = await SharedPreferences.getInstance();
    settings = Settings.decode(_prefs!.getString('settings'));
    try {
      final mp = _prefs!.getString('mealPlan');
      if (mp != null) mealPlan = MealPlan.fromJson(jsonDecode(mp) as Map<String, dynamic>);
      if (mealPlan != null && (mealPlan!.finished || DateTime.now().difference(mealPlan!.started).inHours >= 6)) mealPlan = null;
    } catch (_) {}
    // Never stay on the start screen because the sound player is slow to start.
    try {
      await player.init().timeout(const Duration(seconds: 5));
    } catch (_) {}
    player.onPreviewEnd = notifyListeners;
    player.isMuted = () => settings.flag('muted');
    WidgetsBinding.instance.addObserver(this);
    restartTimers();
    if (settings.str('nsUrl').isNotEmpty) refresh(full: true);
  }

  void restartTimers() {
    _poll?.cancel();
    _tick?.cancel();
    _poll = Timer.periodic(Duration(seconds: math.max(30, settings.integer('refreshSec'))), (_) => refresh());
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => _onTick());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  // ---------- settings ----------

  void save() {
    _prefs?.setString('settings', settings.encode());
    notifyListeners();
  }

  /// Bell button: alarm sounds off / on. Muting stops a sound that is playing.
  void toggleMute() {
    change((s) => s.set('muted', !s.flag('muted')));
    if (settings.flag('muted')) player.silence();
  }

  /// Brightness button: the screen darker / normal.
  void toggleDim() => change((s) => s.set('dimOn', !s.flag('dimOn')));

  void change(void Function(Settings s) f) {
    f(settings);
    save();
  }

  void resetAll() {
    final url = settings.str('nsUrl');
    final token = settings.str('nsToken');
    final api = settings.flag('apiSecret');
    settings = Settings.initial();
    settings.set('nsUrl', url);
    settings.set('nsToken', token);
    settings.set('apiSecret', api);
    save();
  }

  String exportSettings() => settings.encode();

  bool importSettings(String text) {
    final s = Settings.decode(text);
    if (text.trim().isEmpty || !text.contains('"v"')) return false;
    settings = s;
    save();
    restartTimers();
    refresh(full: true);
    return true;
  }

  // ---------- data ----------

  NightscoutClient get client =>
      NightscoutClient(settings.str('nsUrl'), settings.str('nsToken'), settings.flag('apiSecret'));

  bool get mmol => settings.mmol;

  /// Hours for the 5 buttons above the graph (from settings).
  List<int> get graphButtons {
    final raw = settings.raw('graphButtons');
    final list = raw is List ? raw.whereType<num>().map((e) => e.toInt()).where((h) => h >= 1 && h <= 24).toList() : <int>[];
    return list.isEmpty ? const [1, 2, 3, 6, 12] : list;
  }
  Entry? get latest => entries.isEmpty ? null : entries.last;
  ZoneRange get range => activeRange(settings.ranges, DateTime.now());
  Zone? get zone => latest == null ? null : zoneOf(latest!.mg, range);
  Color colorFor(double mg) {
    final r = range;
    return zoneColorIn(zoneOf(mg, r), r);
  }
  Duration? get age => latest == null ? null : DateTime.now().difference(latest!.t);
  double? get delta5 => avgDelta5(entries);
  bool get isStale => age == null || age!.inMinutes >= settings.integer('nightStaleMin');

  Treatment? get lastBolus {
    for (final t in treatments.reversed) {
      if ((t.insulin ?? 0) > 0 && !t.isSmb) return t;
    }
    return null;
  }

  Treatment? get lastCarbs {
    for (final t in treatments.reversed) {
      if ((t.carbs ?? 0) > 0) return t;
    }
    return null;
  }

  Future<String> connect(String url, String token, bool apiSecret, bool mmol) async {
    final c = NightscoutClient(url, token, apiSecret);
    final name = await c.test();
    await c.entriesSince(DateTime.now().subtract(const Duration(hours: 1)), count: 5);
    settings.set('nsUrl', NightscoutClient.normalize(url));
    settings.set('nsToken', token.trim());
    settings.set('apiSecret', apiSecret);
    settings.set('mmol', mmol);
    entries = [];
    treatments = [];
    device = null;
    save();
    await refresh(full: true);
    return name;
  }

  Future<void> refresh({bool full = false}) async {
    if (settings.str('nsUrl').isEmpty || loading) return;
    loading = true;
    final c = client;
    final now = DateTime.now();
    try {
      final since = (full || entries.isEmpty)
          ? now.subtract(const Duration(hours: 26))
          : entries.last.t.subtract(const Duration(minutes: 15));
      final fresh = await c.entriesSince(since);
      final map = <int, Entry>{for (final e in entries) e.t.millisecondsSinceEpoch: e};
      for (final e in fresh) {
        map[e.t.millisecondsSinceEpoch] = e;
      }
      final cut = now.subtract(const Duration(hours: 26));
      entries = map.values.where((e) => e.t.isAfter(cut)).toList()..sort((a, b) => a.t.compareTo(b.t));
      if (full || _n % 3 == 0) {
        treatments = await c.treatmentsSince(now.subtract(const Duration(hours: 24)));
      }
      device = await c.deviceStatus();
      if (full || _n % 15 == 0) {
        // Ages are extras: a problem here must not stop the glucose readings.
        try {
          sensorStart = await c.lastOfTypes(['Sensor Change', 'Sensor Start']) ?? sensorStart;
          siteChange = await c.lastOfTypes(['Site Change']) ?? siteChange;
          insulinChange = await c.lastOfTypes(['Insulin Change']) ?? insulinChange;
          pumpBatteryChange = await c.lastOfTypes(['Pump Battery Change']) ?? pumpBatteryChange;
        } catch (_) {}
        try {
          profiles = await c.profiles();
        } catch (_) {}
      }
      if (full || _n % 2 == 0) {
        try {
          feedProblem = await c.feedProblem();
        } catch (_) {}
      }
      health = Health.fromJson(await c.health());
      error = null;
      internetUp = null;
      lastFetch = now;
    } catch (e) {
      error = e.toString();
      internetUp = await NightscoutClient.internetUp();
    }
    loading = false;
    _n++;
    evaluate();
    notifyListeners();
  }

  /// The flashing message on the top line, and whether Loop uses the backup.
  FaultStatus get faultStatus {
    String site = 'Glucose server';
    try {
      final h = Uri.parse(client.base).host;
      if (h.isNotEmpty) site = h;
    } catch (_) {}
    return diagnose(
      now: DateTime.now(),
      lateMin: settings.integer('faultMin'),
      siteError: error != null,
      internetUp: internetUp,
      siteName: site,
      lastReading: latest?.t,
      lastLoop: device?.loopTime,
      health: health,
    );
  }

  Future<void> postTreatment(Map<String, dynamic> t) async {
    await client.postTreatment(t);
    try {
      treatments = await client.treatmentsSince(DateTime.now().subtract(const Duration(hours: 24)));
    } catch (_) {}
    notifyListeners();
  }

  // ---------- alarms ----------

  int get _nowMinute {
    final n = DateTime.now();
    return n.hour * 60 + n.minute;
  }

  bool _inWindow(int from, int to, int m) {
    if (from == to) return false;
    if (from < to) return m >= from && m < to;
    return m >= from || m < to;
  }

  bool get inQuietHours =>
      settings.flag('quietOn') && _inWindow(settings.integer('quietFrom'), settings.integer('quietTo'), _nowMinute);

  bool _quietMuted(AlarmKind k) =>
      inQuietHours && settings.integer('quietMode') == 0 && !isRedAlarm(k) && k != AlarmKind.noData;

  bool _predictsLow(ZoneRange r) {
    final d = device;
    if (d == null || d.predStart == null || d.predLines.isEmpty) return false;
    if (DateTime.now().difference(d.predStart!).inMinutes > 15) return false;
    final steps = settings.integer('predLowMin') ~/ 5 + 1;
    for (final line in d.predLines) {
      for (var i = 1; i < line.length && i <= steps; i++) {
        if (line[i] < r.yelLo) return true;
      }
    }
    return false;
  }

  // ---------- one-time target alert ----------

  void startTarget(TargetWatch w) {
    target = w;
    targetHit = null;
    notifyListeners();
  }

  void cancelTarget() {
    target = null;
    notifyListeners();
  }

  void _checkTarget() {
    final w = target;
    if (w == null) return;
    final l = latest;
    final now = DateTime.now();
    // Only readings that arrive after the alert was turned on count.
    if (l != null && l.t.isAfter(w.started)) {
      final reached = w.rising ? l.mg >= w.mg - 0.01 : l.mg <= w.mg + 0.01;
      if (reached) {
        _fireTarget(w, true, l.mg);
        return;
      }
    }
    if (w.expires != null && now.isAfter(w.expires!)) {
      if (w.timeUpAlert) {
        _fireTarget(w, false, l?.mg);
      } else {
        target = null;
        notifyListeners();
      }
    }
  }

  void _fireTarget(TargetWatch w, bool reached, double? mg) {
    target = null;
    targetHit = TargetHit(w, reached, mg);
    if (w.sound || w.vibrate) {
      player.start(
        SoundCfg(sound: w.soundIndex, volMode: 0, v1: w.volume, v2: w.volume, secs: 60, vibrate: w.vibrate),
        vibrateOnly: !w.sound,
      );
    }
    final nav = navKey?.currentState;
    if (nav != null && !_targetOpen) {
      _targetOpen = true;
      nav
          .push(MaterialPageRoute<void>(builder: (_) => const TargetAlertScreen(), fullscreenDialog: true))
          .then((_) => _targetOpen = false);
    }
    notifyListeners();
  }

  void dismissTarget() {
    targetHit = null;
    player.stop();
    // A regular alarm that was sounding starts again if it still applies.
    active = null;
    notifyListeners();
    evaluate();
  }

  /// Works out which alarm (if any) should be sounding now.
  void evaluate() {
    _checkMealPlan();
    if (dueStep != null) return; // the meal step has the sound for now
    _checkTarget();
    if (targetHit != null) return; // the target alert has the sound for now
    if (active?.test == true) return;
    final s = settings;
    final now = DateTime.now();
    snoozes.removeWhere((k, v) => now.isAfter(v.until));
    final l = latest;

    if (l != null && s.flag('smartSnooze')) {
      for (final k in [AlarmKind.redLow, AlarmKind.yellowLow, AlarmKind.predictedLow]) {
        final sn = snoozes[k];
        if (sn != null && sn.level != null && l.mg < sn.level! - 11) snoozes.remove(k);
      }
      for (final k in [AlarmKind.yellowHigh, AlarmKind.redHigh]) {
        final sn = snoozes[k];
        if (sn != null && sn.level != null && l.mg > sn.level! + 27) snoozes.remove(k);
      }
    }

    final cands = <AlarmKind>[];
    if (s.str('nsUrl').isNotEmpty) {
      if (l == null || now.difference(l.t).inMinutes >= s.integer('noDataMin')) {
        if (s.flag('noDataOn') && lastFetch != null) cands.add(AlarmKind.noData);
      } else {
        final r = range;
        final z = zoneOf(l.mg, r);
        if (z == Zone.redLow && s.sounds[0].enabled) cands.add(AlarmKind.redLow);
        if (z == Zone.yellowLow && s.sounds[1].enabled) cands.add(AlarmKind.yellowLow);
        if (z == Zone.redHigh && s.sounds[3].enabled) cands.add(AlarmKind.redHigh);
        if (z == Zone.yellowHigh && s.sounds[2].enabled) cands.add(AlarmKind.yellowHigh);
        if (z != Zone.redLow && z != Zone.yellowLow && s.flag('predLowOn') && s.sounds[1].enabled && _predictsLow(r)) {
          cands.add(AlarmKind.predictedLow);
        }
      }
      final d = device;
      if (d != null && s.sounds[4].enabled) {
        if (s.flag('loopOn') && d.loopTime != null && now.difference(d.loopTime!).inMinutes >= s.integer('loopMin')) {
          cands.add(AlarmKind.loop);
        }
        if (s.flag('reservoirOn') && d.reservoir != null && d.reservoir! < s.integer('reservoirU')) {
          cands.add(AlarmKind.reservoir);
        }
        if (s.flag('pumpBatOn') && d.pumpBattery != null && d.pumpBattery! < s.integer('pumpBatPct')) {
          cands.add(AlarmKind.pumpBattery);
        }
      }
    }

    AlarmKind? pick;
    for (final k in cands) {
      if (snoozes.containsKey(k) || _quietMuted(k)) continue;
      pick = k;
      break;
    }

    if (pick == null) {
      if (active != null) {
        active = null;
        player.stop();
      }
      return;
    }
    if (active?.kind == pick) return;
    _startAlarm(pick, now);
  }

  void _startAlarm(AlarmKind kind, DateTime now, {bool test = false}) {
    final s = settings;
    final cfg = s.sounds[soundGroup(kind)];
    final quiet = inQuietHours && !isRedAlarm(kind);
    final mode = s.integer('quietMode');
    final gentle = s.flag('gentleOn') && !(isRedAlarm(kind) && s.flag('urgentSkipsGentle'));
    active = ActiveAlarm(kind, now, gentle: gentle, test: test);
    player.start(
      cfg,
      delaySec: gentle ? s.integer('flashSec') : 0,
      volumeScale: quiet && mode == 1 ? 0.5 : 1.0,
      vibrateOnly: quiet && mode == 2,
    );
    _openAlert();
    notifyListeners();
  }

  void testAlarm(AlarmKind kind) => _startAlarm(kind, DateTime.now(), test: true);

  /// True during the gentle wake-up part (screen flashing, no sound yet).
  bool get flashing {
    final a = active;
    if (a == null || !a.gentle) return false;
    return DateTime.now().difference(a.started).inSeconds < settings.integer('flashSec');
  }

  int maxSnoozeFor(AlarmKind k) {
    var m = settings.integer('maxSnoozeMin');
    if (isRedAlarm(k)) m = math.min(m, settings.integer('maxRedSnooze'));
    return m;
  }

  void snooze(int minutes) {
    final a = active;
    if (a == null) return;
    final now = DateTime.now();
    if (!a.test) {
      final m = math.min(minutes, maxSnoozeFor(a.kind));
      final sn = Snooze(now.add(Duration(minutes: m)), latest?.mg);
      snoozes[a.kind] = sn;
      if (!settings.flag('wakeIfUrgent')) {
        if (a.kind == AlarmKind.yellowLow) snoozes[AlarmKind.redLow] = sn;
        if (a.kind == AlarmKind.yellowHigh) snoozes[AlarmKind.redHigh] = sn;
      }
    }
    active = null;
    player.stop();
    notifyListeners();
    evaluate();
  }

  void cancelSnooze(AlarmKind k) {
    snoozes.remove(k);
    evaluate();
    notifyListeners();
  }

  // ---------- screens opened by the app itself ----------

  void _openAlert() {
    if (alertOpen) return;
    final nav = navKey?.currentState;
    if (nav == null) return;
    alertOpen = true;
    nav
        .push(MaterialPageRoute<void>(builder: (_) => const AlertScreen(), fullscreenDialog: true))
        .then((_) => alertOpen = false);
  }

  void openNight() {
    if (nightOpen) return;
    final nav = navKey?.currentState;
    if (nav == null) return;
    nightOpen = true;
    nav.push(MaterialPageRoute<void>(builder: (_) => const NightScreen())).then((_) => nightOpen = false);
  }

  void openChecklist() {
    if (checklistOpen) return;
    final nav = navKey?.currentState;
    if (nav == null) return;
    checklistOpen = true;
    nav.push(MaterialPageRoute<void>(builder: (_) => const ChecklistScreen())).then((_) => checklistOpen = false);
  }

  void _onTick() {
    evaluate();
    final now = DateTime.now();
    final key = '${now.year}-${now.month}-${now.day}';
    final m = _nowMinute;
    if (settings.flag('ckOn') && _lastChecklist != key) {
      final at = settings.integer('ckAt');
      if (m >= at && m < at + 3) {
        _lastChecklist = key;
        if (!nightOpen && !alertOpen) openChecklist();
      }
    }
    if (settings.flag('nightAutoOn') && _lastAutoNight != key) {
      final from = settings.integer('nightFrom');
      if (m >= from && m < from + 3) {
        _lastAutoNight = key;
        if (!alertOpen) openNight();
      }
    }
    notifyListeners();
  }

  // ---------- meal insulin plan ----------

  void _saveMealPlan() {
    try {
      final p = mealPlan;
      if (p == null || p.finished) {
        _prefs?.remove('mealPlan');
      } else {
        _prefs?.setString('mealPlan', jsonEncode(p.toJson()));
      }
    } catch (_) {}
  }

  void startMealPlan(MealPlan p) {
    mealPlan = p;
    dueStep = null;
    _saveMealPlan();
    notifyListeners();
  }

  void cancelMealPlan() {
    mealPlan = null;
    if (dueStep != null) player.stop();
    dueStep = null;
    _saveMealPlan();
    notifyListeners();
  }

  /// A step was given (sent to Loop or given by hand) or skipped.
  void mealStepFinished(MealStep s, {bool skipped = false}) {
    s.state = skipped ? MealStepState.skipped : MealStepState.done;
    if (identical(dueStep, s)) {
      dueStep = null;
      player.stop();
    }
    if (mealPlan?.finished ?? false) mealPlan = null;
    _saveMealPlan();
    notifyListeners();
  }

  /// Ring again in [min] minutes.
  void snoozeMealStep(MealStep s, int min) {
    s.at = DateTime.now().add(Duration(minutes: min));
    if (identical(dueStep, s)) {
      dueStep = null;
      player.stop();
    }
    _saveMealPlan();
    notifyListeners();
  }

  void _checkMealPlan() {
    final p = mealPlan;
    if (p == null || dueStep != null) return;
    final s = p.next;
    if (s == null) return;
    final l = latest;
    final why = stepDueReason(s, now: DateTime.now(), planStarted: p.started, latestMg: l?.mg, latestTime: l?.t);
    if (why == null) return;
    dueStep = s;
    dueReason = why;
    final t = settings;
    player.start(SoundCfg(sound: t.integer('tgtSound'), volMode: 0, v1: t.integer('tgtVolume'), v2: t.integer('tgtVolume'), secs: 60, vibrate: true));
    final nav = navKey?.currentState;
    if (nav != null && !_stepOpen) {
      _stepOpen = true;
      nav.push(MaterialPageRoute<void>(builder: (_) => MealStepScreen(step: s), fullscreenDialog: true)).then((_) => _stepOpen = false);
    }
    notifyListeners();
  }

  // ---------- food ----------

  Future<void> loadFoods() async {
    try {
      foods = await client.foods();
      foods.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      foodsLoaded = true;
      foodsError = null;
    } catch (e) {
      foodsError = e.toString();
    }
    notifyListeners();
  }

  Future<Food> saveFood(Food f) async {
    final saved = await client.saveFood(f);
    foods.removeWhere((x) => x.id != null && x.id == saved.id);
    foods.add(saved);
    foods.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    notifyListeners();
    return saved;
  }

  Future<void> deleteFood(Food f) async {
    if (f.id != null) await client.deleteFood(f.id!);
    foods.remove(f);
    meal.items.removeWhere((i) => identical(i.food, f));
    notifyListeners();
  }

  /// The food already saved with this barcode, if any.
  Food? foodByBarcode(String code) {
    final c = code.replaceAll(RegExp(r'[^0-9]'), '');
    for (final f in foods) {
      final b = f.barcode.replaceAll(RegExp(r'[^0-9]'), '');
      if (b.isNotEmpty && (b == c || b.padLeft(13, '0') == c.padLeft(13, '0'))) return f;
    }
    return null;
  }

  void mealChanged() => notifyListeners();

  // ---------- school lunch ----------

  /// School lunches by day (YYYY-MM-DD), from the site's food list.
  Map<String, SchoolLunch> lunches = {};
  bool lunchesLoaded = false;

  Future<void> loadLunches() async {
    final docs = await client.foodDocs(SchoolLunch.type);
    final m = <String, SchoolLunch>{};
    for (final d in docs) {
      final l = SchoolLunch.fromJson(d);
      if (l == null) continue;
      // Two for the same day (made at the same time on two phones): keep the fuller one.
      final had = m[l.date];
      if (had == null || l.items.length + l.eaten.length > had.items.length + had.eaten.length) m[l.date] = l;
    }
    lunches = m;
    lunchesLoaded = true;
    notifyListeners();
  }

  SchoolLunch? lunchFor(String day) => lunches[day];

  /// Today's lunch with something still in the box.
  SchoolLunch? get lunchToday {
    final l = lunches[SchoolLunch.dayKey(DateTime.now())];
    return l != null && l.waiting.isNotEmpty ? l : null;
  }

  /// Changes a lunch on the site: reads its latest copy first (another phone
  /// may have changed it), applies [change], saves.
  Future<SchoolLunch> changeLunch(String day, void Function(SchoolLunch l) change) async {
    try {
      await loadLunches();
    } catch (_) {}
    final l = lunches[day] ?? SchoolLunch(day);
    change(l);
    l.id = await client.saveFoodDoc(l.toJson());
    lunches[day] = l;
    notifyListeners();
    return l;
  }

  Future<void> deleteLunch(String day) async {
    final l = lunches[day];
    if (l?.id != null) await client.deleteFood(l!.id!);
    lunches.remove(day);
    notifyListeners();
  }
}
