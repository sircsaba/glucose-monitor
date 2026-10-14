import 'dart:async' show Timer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../alarm/alarm_player.dart';
import '../data/nightscout.dart';
import '../logic/glucose.dart';
import '../ui/alert_screen.dart';
import '../ui/checklist_screen.dart';
import '../ui/night_screen.dart';
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
  DateTime? lastFetch;
  bool loading = false;

  ActiveAlarm? active;
  final Map<AlarmKind, Snooze> snoozes = {};
  bool alertOpen = false;
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
    await player.init();
    player.onPreviewEnd = notifyListeners;
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
  Color colorFor(double mg) => zoneColor(zoneOf(mg, range));
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
      }
      error = null;
      lastFetch = now;
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    _n++;
    evaluate();
    notifyListeners();
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

  /// Works out which alarm (if any) should be sounding now.
  void evaluate() {
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
}
