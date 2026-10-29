import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../data/nightscout.dart';
import '../logic/bolus_calc.dart';
import '../logic/device_lock.dart';
import '../logic/glucose.dart';
import '../logic/otp.dart';
import '../logic/profile.dart';
import '../logic/qr.dart';
import '../plus.dart';
import '../state/app_state.dart';
import '../state/settings.dart';
import 'bolus_calc_view.dart';
import 'common.dart';

/// Kept in the phone's secure storage (Keychain / Android keystore).
class RemoteSecrets {
  static const _s = FlutterSecureStorage();
  static Future<String?> read(String k) async {
    try {
      return await _s.read(key: k);
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String k, String? v) async {
    try {
      if (v == null || v.isEmpty) {
        await _s.delete(key: k);
      } else {
        await _s.write(key: k, value: v);
      }
    } catch (_) {}
  }

  static const otpUrl = 'gm_otp_url';
  static const apiSecret = 'gm_cmd_secret';
  static const cmdUrl = 'gm_cmd_url';
  static const cmdSecret = 'gm_cmd_url_secret';
}

/// Loop remote control (Monitor Glucose Plus): overrides, carbs and boluses,
/// sent through Nightscout or your own server with Apple's push service. No
/// Apple keys here: the site has them. Loop's device token comes from the
/// profile; carbs and boluses need Loop's one-time password (its QR code,
/// read once).
const Color _kOn = Color(0xFF2E9E4F); // an override is running

String _presetLabel(ProfileDoc? loop, String name) {
  for (final p in loop?.presets ?? const <OverridePreset>[]) {
    if (p.name == name) return p.label;
  }
  return name;
}

class RemoteScreen extends StatefulWidget {
  /// Carbs to start with, and what was eaten (from a meal on the Food screen).
  final double? carbs;
  final String? mealNote;
  const RemoteScreen({super.key, this.carbs, this.mealNote});
  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  Totp? _totp;
  String? _savedSecret; // API secret remembered on this phone
  String? _cmdUrl; // another site for commands ('' = the connected site)
  String? _cmdSecret;
  late double _carbs = widget.carbs?.roundToDouble() ?? 20;
  double _absorption = 3;
  int _carbsAgo = 0; // minutes
  double _bolus = 0.5;
  bool _bolusEdited = false; // false: the calculator's suggestion
  double _carbInsulin = 0;
  bool _carbInsulinEdited = false;
  bool _sending = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _loadSecrets();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _totp != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _loadSecrets() async {
    final otp = await RemoteSecrets.read(RemoteSecrets.otpUrl);
    final sec = await RemoteSecrets.read(RemoteSecrets.apiSecret);
    final url = await RemoteSecrets.read(RemoteSecrets.cmdUrl);
    final usec = await RemoteSecrets.read(RemoteSecrets.cmdSecret);
    if (!mounted) return;
    setState(() {
      _totp = otp == null ? null : Totp.parse(otp);
      _savedSecret = sec;
      _cmdUrl = url ?? '';
      _cmdSecret = usec;
    });
  }

  Settings get s => app.settings;
  double get _maxBolus => s.number('remoteMaxBolus');
  double get _maxCarbs => s.number('remoteMaxCarbs');

  ProfileDoc? get _loop {
    for (final p in app.profiles) {
      if (p.isLoop) return p;
    }
    return null;
  }

  bool get _otherSite => (_cmdUrl ?? '').isNotEmpty;

  NightscoutClient get _client => _otherSite ? NightscoutClient(_cmdUrl!, _cmdSecret ?? '', true) : app.client;

  String get _siteName => _otherSite ? Uri.tryParse(_cmdUrl!)?.host ?? _cmdUrl! : (Uri.tryParse(NightscoutClient.normalize(s.str('nsUrl')))?.host ?? 'your site');

  /// The API secret to send with: the app's own (connected with the secret),
  /// the one remembered here, or asked now.
  Future<String?> _secret() async {
    if (_otherSite) return _cmdSecret ?? '';
    if (s.flag('apiSecret')) return '';
    if (_savedSecret != null && _savedSecret!.isNotEmpty) return _savedSecret;
    final ctl = TextEditingController();
    var remember = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('API secret'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Sending commands through $_siteName needs its API secret.', style: const TextStyle(color: kMuted, fontSize: 13)),
            const SizedBox(height: 10),
            TextField(controller: ctl, obscureText: true, autofocus: true, decoration: const InputDecoration(labelText: 'API secret')),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: remember,
              onChanged: (v) => set(() => remember = v ?? true),
              title: const Text('Remember on this phone (secure storage)'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('OK')),
          ],
        ),
      ),
    );
    if (ok != true || ctl.text.isEmpty) return null;
    if (remember) {
      await RemoteSecrets.write(RemoteSecrets.apiSecret, ctl.text);
      _savedSecret = ctl.text;
    }
    return ctl.text;
  }

  /// Loop's one-time password: worked out from its QR code, or typed.
  Future<String?> _otp() async {
    final t = _totp;
    if (t != null) {
      // A code about to change may be refused: wait for the next one.
      if (t.secondsLeft() <= 2) await Future.delayed(Duration(seconds: t.secondsLeft() + 1));
      return t.code();
    }
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('One-time password'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Type the 6-digit code shown in Loop › Settings › Services › Nightscout › One-Time Password. '
              'Or set up the QR code once (gear button) and it is filled in for you.', style: TextStyle(color: kMuted, fontSize: 13)),
          TextField(
            controller: ctl,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 8,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Code'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('OK')),
        ],
      ),
    );
    return ok == true && ctl.text.length >= 6 ? ctl.text : null;
  }

  Future<bool> _confirm(String title, String body, {bool danger = false}) async {
    var armed = !danger;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        if (!armed) {
          // A bolus can only be confirmed after 2 seconds (no double tap by mistake).
          Future.delayed(const Duration(seconds: 2), () {
            if (c.mounted) set(() => armed = true);
          });
        }
        return AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: armed ? () => Navigator.pop(c, true) : null, child: const Text('Send to Loop')),
          ],
        );
      }),
    );
    return ok == true;
  }

  /// Sends one command. True when the site accepted it.
  Future<bool> _send(Map<String, dynamic> body, {String? secret}) async {
    secret ??= await _secret();
    if (secret == null) return false;
    setState(() => _sending = true);
    var ok = false;
    try {
      await _client.sendLoopCommand({
        ...body,
        'enteredBy': s.str('remoteName').isEmpty ? kAppName : s.str('remoteName'),
        'created_at': body['created_at'] ?? DateTime.now().toUtc().toIso8601String(),
      }, secret: secret.isEmpty ? null : secret);
      ok = true;
      // Look for Loop's upload a little later.
      Future.delayed(const Duration(seconds: 25), () => app.refresh(full: true));
      Future.delayed(const Duration(seconds: 70), () => app.refresh(full: true));
    } catch (e) {
      if (e.toString().contains('API secret') && !_otherSite) {
        await RemoteSecrets.write(RemoteSecrets.apiSecret, null);
        _savedSecret = null;
      }
      _snack('Not sent: $e', long: true);
    }
    if (mounted) setState(() => _sending = false);
    return ok;
  }

  /// The phone's lock (PIN / Face ID / fingerprint) before anything goes to Loop.
  Future<bool> _unlock(String what) async {
    final err = await confirmDeviceLock('Send to Loop: $what');
    if (err != null) _snack(err, long: true);
    return err == null;
  }

  Future<void> _sent(String title, List<String> lines) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: kGreen, size: 36),
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(l, style: const TextStyle(fontSize: 15))),
          const SizedBox(height: 8),
          const Text('Loop shows its own notification on the Loop phone. The entry appears here within a minute or two.',
              style: TextStyle(color: kMuted, fontSize: 12)),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
  }

  /// A fresh one-time code, different from [used] (Loop accepts each code once).
  Future<String?> _nextOtp(String? used) async {
    final t = _totp;
    if (t != null && used != null && t.code() == used) {
      _snack('Waiting ${t.secondsLeft()} s for the next one-time code…');
      await Future.delayed(Duration(seconds: t.secondsLeft() + 1));
    }
    return _otp();
  }

  void _snack(String m, {bool long = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: Duration(seconds: long ? 8 : 4)));
  }

  // ------------------------------------------------------------ commands

  Future<void> _override(OverridePreset p) async {
    final choices = <(String, int?)>[
      if (p.durationMin != null) ('As set in Loop (${_mins(p.durationMin!)})', p.durationMin) else ('Until cancelled (as set)', null),
      ('30 min', 30),
      ('1 hour', 60),
      ('2 hours', 120),
      ('3 hours', 180),
      if (p.durationMin != null) ('Until cancelled', 0),
    ];
    final pick = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: kCard,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(p.label, style: const TextStyle(fontWeight: FontWeight.w600)), subtitle: Text(_presetInfo(p))),
          for (var i = 0; i < choices.length; i++) ListTile(title: Text(choices[i].$1), onTap: () => Navigator.pop(c, i)),
        ]),
      ),
    );
    if (pick == null) return;
    final dur = choices[pick].$2;
    if (!await _confirm('Start override?', '${p.label}\n${choices[pick].$1}')) return;
    if (!await _unlock('override ${p.label}')) return;
    if (await _send({
      'eventType': 'Temporary Override',
      'reason': p.name,
      'reasonDisplay': p.label,
      if (dur != null && dur > 0) 'duration': dur,
    })) {
      await _sent('Override sent', ['${p.label}', choices[pick].$1]);
    }
  }

  Future<void> _cancelOverride() async {
    if (!await _confirm('Cancel the override?', 'Loop goes back to its normal settings.')) return;
    if (!await _unlock('cancel the override')) return;
    if (await _send({'eventType': 'Temporary Override Cancel'})) await _sent('Cancel sent', ['Override cancelled']);
  }

  Future<void> _sendCarbs(double insulin) async {
    if (_carbs > _maxCarbs) return _snack('More than your limit of ${_maxCarbs.round()} g (gear button)');
    final limit = _bolusLimit;
    if (insulin > limit + 0.0001) return _snack('More than the bolus limit of ${fmtU(limit)} U');
    final when = _carbsAgo == 0 ? 'now' : '$_carbsAgo min ago';
    final what = '${_carbs.round()} g${insulin > 0 ? ' + ${fmtU(insulin)} U' : ''}';
    if (!await _confirm(insulin > 0 ? 'Send carbs and bolus to Loop?' : 'Send carbs to Loop?',
        '${_carbs.round()} g, absorption ${fmtU(_absorption)} h, eaten $when'
        '${insulin > 0 ? '\nBolus ${fmtU(insulin)} U\n\nLoop checks the bolus against its own limits before giving it.' : ''}',
        danger: insulin > 0)) {
      return;
    }
    if (!await _unlock(what)) return;
    final secret = await _secret();
    if (secret == null) return;
    final otp = await _otp();
    if (otp == null) return;
    final carbsOk = await _send({
      'eventType': 'Remote Carbs Entry',
      'remoteCarbs': _carbs.round(),
      'remoteAbsorption': _absorption,
      'otp': otp,
      'created_at': DateTime.now().subtract(Duration(minutes: _carbsAgo)).toUtc().toIso8601String(),
    }, secret: secret);
    if (!carbsOk) return;
    final lines = ['${_carbs.round()} g carbs (absorption ${fmtU(_absorption)} h, eaten $when)'];
    if (widget.mealNote != null && !app.meal.isEmpty) {
      // What was eaten, kept on the site for later analysis (Loop records only the carbs).
      final m = app.meal;
      try {
        await app.postTreatment({
          'eventType': 'Note',
          'created_at': DateTime.now().subtract(Duration(minutes: _carbsAgo)).toUtc().toIso8601String(),
          'enteredBy': 'Monitor Glucose Plus',
          'notes': 'Meal: ${widget.mealNote}',
          'foods': m.toFoodsJson(),
          ...m.total.toJson(),
        });
      } catch (_) {}
      m.items.clear();
      app.mealChanged();
    }
    if (insulin > 0) {
      final otp2 = await _nextOtp(otp);
      if (otp2 == null) {
        lines.add('Bolus NOT sent (no one-time code)');
      } else if (await _send({'eventType': 'Remote Bolus Entry', 'remoteBolus': insulin, 'otp': otp2}, secret: secret)) {
        lines.add('${fmtU(insulin)} U bolus');
      } else {
        lines.add('Bolus NOT sent (see the message)');
      }
    }
    setState(() => _carbInsulinEdited = false);
    await _sent(insulin > 0 ? 'Carbs and bolus sent' : 'Carbs sent', lines);
  }

  double get _bolusLimit {
    final loopMax = _loop?.maxBolus;
    return loopMax == null ? _maxBolus : math.min(_maxBolus, loopMax);
  }

  Future<void> _sendBolus(double bolus) async {
    final limit = _bolusLimit;
    if (bolus <= 0) return _snack('Nothing to send: the bolus is 0 U');
    if (bolus > limit + 0.0001) return _snack('More than the limit of ${fmtU(limit)} U');
    if (!await _confirm('Send a bolus to Loop?', '${fmtU(bolus)} U\n\nLoop checks it against its own limits before giving it.', danger: true)) return;
    if (!await _unlock('${fmtU(bolus)} U bolus')) return;
    final otp = await _otp();
    if (otp == null) return;
    if (await _send({'eventType': 'Remote Bolus Entry', 'remoteBolus': bolus, 'otp': otp})) {
      setState(() => _bolusEdited = false);
      await _sent('Bolus sent', ['${fmtU(bolus)} U bolus']);
    }
  }

  // ------------------------------------------------------------ settings

  Future<void> _setupOtp() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kCard,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(
            title: Text('Loop\'s one-time password', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('On the Loop phone: Settings › Services › Nightscout › One-Time Password shows a QR code.'),
          ),
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Take a photo of the QR code'), onTap: () => Navigator.pop(c, 'camera')),
          ListTile(leading: const Icon(Icons.image_outlined), title: const Text('Choose a screenshot of it'), onTap: () => Navigator.pop(c, 'gallery')),
          ListTile(leading: const Icon(Icons.paste), title: const Text('Paste the otpauth:// link'), onTap: () => Navigator.pop(c, 'paste')),
          if (_totp != null)
            ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Remove it from this phone'), onTap: () => Navigator.pop(c, 'remove')),
        ]),
      ),
    );
    if (how == null) return;
    String? url;
    if (how == 'remove') {
      await RemoteSecrets.write(RemoteSecrets.otpUrl, null);
      setState(() => _totp = null);
      return;
    } else if (how == 'paste') {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      url = data?.text;
    } else {
      try {
        final f = await ImagePicker().pickImage(source: how == 'camera' ? ImageSource.camera : ImageSource.gallery, maxWidth: 2000);
        if (f == null) return;
        url = readQr(await f.readAsBytes());
        if (url == null) return _snack('No QR code found in this picture. Try closer, straight on, or a screenshot.', long: true);
      } catch (e) {
        return _snack('Could not open the picture: $e', long: true);
      }
    }
    final t = url == null ? null : Totp.parse(url);
    if (t == null) return _snack('This is not Loop\'s one-time password (an otpauth://totp link).', long: true);
    await RemoteSecrets.write(RemoteSecrets.otpUrl, url!.trim());
    setState(() => _totp = t);
    _snack('One-time password saved. Check that the code here matches the one in Loop.');
  }

  Future<void> _settings() async {
    final urlCtl = TextEditingController(text: _cmdUrl ?? '');
    final secCtl = TextEditingController(text: _cmdSecret ?? '');
    final nameCtl = TextEditingController(text: s.str('remoteName'));
    await showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        void change(void Function(Settings x) f) {
          app.change(f);
          set(() {});
        }

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(c).viewInsets.bottom),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Remote control settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                StepRow(
                  label: 'Largest bolus allowed',
                  hint: 'Here, before Loop checks its own maximum',
                  value: '${fmtU(s.number('remoteMaxBolus'))} U',
                  onMinus: () => change((x) => x.set('remoteMaxBolus', ((x.number('remoteMaxBolus') - 0.5).clamp(0.5, 30.0) * 100).round() / 100)),
                  onPlus: () => change((x) => x.set('remoteMaxBolus', ((x.number('remoteMaxBolus') + 0.5).clamp(0.5, 30.0) * 100).round() / 100)),
                ),
                StepRow(
                  label: 'Most carbs allowed',
                  value: '${s.number('remoteMaxCarbs').round()} g',
                  onMinus: () => change((x) => x.set('remoteMaxCarbs', (x.number('remoteMaxCarbs') - 10).clamp(10.0, 250.0))),
                  onPlus: () => change((x) => x.set('remoteMaxCarbs', (x.number('remoteMaxCarbs') + 10).clamp(10.0, 250.0))),
                ),
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: 'Your name (shown in Loop)', hintText: kAppName),
                  onChanged: (v) => app.change((x) => x.set('remoteName', v.trim())),
                ),
                const SizedBox(height: 16),
                const Text('Send commands through', style: TextStyle(color: kMuted, fontSize: 13)),
                const Text('Empty: the site this app shows (Nightscout or your server). Or another Nightscout, with its API secret.',
                    style: TextStyle(color: kMuted, fontSize: 12)),
                TextField(controller: urlCtl, decoration: const InputDecoration(labelText: 'Other site address (optional)', hintText: 'https://…')),
                TextField(controller: secCtl, obscureText: true, decoration: const InputDecoration(labelText: 'Its API secret')),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () async {
                    final u = urlCtl.text.trim();
                    await RemoteSecrets.write(RemoteSecrets.cmdUrl, u.isEmpty ? null : u);
                    await RemoteSecrets.write(RemoteSecrets.cmdSecret, u.isEmpty ? null : secCtl.text);
                    setState(() {
                      _cmdUrl = u;
                      _cmdSecret = u.isEmpty ? null : secCtl.text;
                    });
                    if (c.mounted) Navigator.pop(c);
                  },
                  child: const Text('Save'),
                ),
                if (_savedSecret != null)
                  TextButton(
                    onPressed: () async {
                      await RemoteSecrets.write(RemoteSecrets.apiSecret, null);
                      setState(() => _savedSecret = null);
                      set(() {});
                    },
                    child: const Text('Forget the API secret saved on this phone'),
                  ),
              ]),
            ),
          ),
        );
      }),
    );
  }

  // ------------------------------------------------------------ view

  static String _mins(int m) => m % 60 == 0 ? '${m ~/ 60} h' : (m > 60 ? '${m ~/ 60} h ${m % 60} min' : '$m min');

  String _presetInfo(OverridePreset p) {
    final parts = <String>[
      if (p.scale != null && (p.scale! - 1).abs() > 0.001) 'insulin ${(p.scale! * 100).round()}%',
      if (p.targetLo != null) 'target ${fmtBg(p.targetLo!, app.mmol)}–${fmtBg(p.targetHi ?? p.targetLo!, app.mmol)}',
      p.durationMin == null ? 'until cancelled' : _mins(p.durationMin!),
    ];
    return parts.join(' · ');
  }

  /// The override running now: from Loop's latest status upload (every 5
  /// minutes), or else from the override treatments.
  ({String name, DateTime? end})? get _activeOverride {
    final d = app.device;
    if (d != null && d.overrideSeen) {
      return d.overrideActive ? (name: d.overrideName, end: d.overrideEnd) : null;
    }
    Treatment? last;
    final list = app.treatments.where((t) => t.type == 'Temporary Override').toList()..sort((a, b) => a.t.compareTo(b.t));
    for (final t in list) {
      last = t;
    }
    if (last == null) return null;
    if ((last.duration ?? 0) <= 0 && !last.indefinite) return null;
    final end = last.indefinite ? null : last.t.add(Duration(seconds: ((last.duration ?? 0) * 60).round()));
    if (end != null && end.isBefore(DateTime.now())) return null;
    return (name: last.reason, end: end);
  }

  Widget _calcTile(BolusCalc c) => Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 6),
          title: Text('Calculation: ${fmtU(c.total)} U', style: const TextStyle(fontSize: 13, color: kAccent)),
          children: [BolusSummary(c)],
        ),
      );

  Widget _card(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...children,
        ]),
      );

  Widget _check(bool ok, String text, {VoidCallback? fix, String fixLabel = 'Set up'}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(ok ? Icons.check_circle : Icons.error_outline, size: 18, color: ok ? kGreen : kAmber),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          if (fix != null) TextButton(onPressed: fix, child: Text(fixLabel)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Loop remote control'), actions: [
        IconButton(tooltip: 'Settings', icon: const Icon(Icons.tune), onPressed: _settings),
      ]),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final loop = _loop;
          final active = _activeOverride;
          final t = _totp;
          final hasSecret = _otherSite ? (_cmdSecret ?? '').isNotEmpty : (s.flag('apiSecret') || (_savedSecret ?? '').isNotEmpty);
          final loopMax = loop?.maxBolus;
          final bolusLimit = _bolusLimit;
          // Bolus calculator: carbs card (carbs + correction − IOB) and bolus card (correction − IOB).
          final calcCarbs = BolusCalc.now(carbs: _carbs);
          final calcBolus = BolusCalc.now();
          double lim(double u) => u > bolusLimit ? (bolusLimit * 20).floor() / 20 : u;
          final carbInsulin = _carbInsulinEdited ? _carbInsulin : lim(calcCarbs.total);
          final bolus = _bolusEdited ? _bolus : lim(calcBolus.total);
          final allReady = loop?.deviceToken != null && hasSecret && t != null;
          final checks = <Widget>[
            Text('Commands go through $_siteName, which sends them to the Loop phone with Apple\'s push service.',
                style: const TextStyle(color: kMuted, fontSize: 12)),
            const SizedBox(height: 4),
            _check(loop?.deviceToken != null,
                loop == null ? 'No Loop profile on this site yet' : (loop.deviceToken == null ? 'Loop profile without a device token' : 'Loop phone found (${loop.bundleId ?? 'Loop'})')),
            _check(hasSecret, hasSecret ? 'API secret available' : 'API secret: asked when you send', fix: hasSecret ? null : () => _secret().then((_) => setState(() {})), fixLabel: 'Enter'),
            _check(t != null, t != null ? 'One-time password set: ${t.code()} (${t.secondsLeft()} s)' : 'One-time password: needed for carbs and bolus',
                fix: _setupOtp, fixLabel: t != null ? 'Change' : 'Set up'),
          ];
          return AbsorbPointer(
            absorbing: _sending,
            child: ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 30), children: [
              if (!allReady) _card('Ready?', checks),
              _card('Override', [
                if (active != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                        'Running: ${active.name.isEmpty ? 'override' : _presetLabel(loop, active.name)}'
                        '${active.end == null ? ' (until cancelled)' : ' until ${fmtClock(active.end!, s.flag('time24'))}'}',
                        style: const TextStyle(color: _kOn, fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                if (loop == null || loop.presets.isEmpty)
                  const Text('No override presets in Loop\'s profile yet.', style: TextStyle(color: kMuted, fontSize: 13))
                else
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final p in loop.presets)
                      ActionChip(
                        label: Text(p.label,
                            style: active != null && active.name == p.name
                                ? const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)
                                : null),
                        backgroundColor: active != null && active.name == p.name ? _kOn : null,
                        side: active != null && active.name == p.name ? const BorderSide(color: _kOn) : null,
                        onPressed: () => _override(p),
                      ),
                  ]),
                const SizedBox(height: 8),
                if (active != null)
                  OutlinedButton.icon(onPressed: _cancelOverride, icon: const Icon(Icons.stop_circle_outlined), label: const Text('Cancel override'))
                else
                  const Text('No override running', style: TextStyle(color: kMuted, fontSize: 13)),
              ]),
              _card('Carbs', [
                StepRow(
                  label: 'Carbs',
                  value: '${_carbs.round()} g',
                  onMinus: () => setState(() => _carbs = (_carbs - 5).clamp(1.0, _maxCarbs)),
                  onPlus: () => setState(() => _carbs = (_carbs + 5).clamp(1.0, _maxCarbs)),
                ),
                StepRow(
                  label: 'Absorption time',
                  value: '${fmtU(_absorption)} h',
                  onMinus: () => setState(() => _absorption = (_absorption - 0.5).clamp(0.5, 8.0)),
                  onPlus: () => setState(() => _absorption = (_absorption + 0.5).clamp(0.5, 8.0)),
                ),
                StepRow(
                  label: 'Eaten',
                  value: _carbsAgo == 0 ? 'now' : '$_carbsAgo min ago',
                  onMinus: () => setState(() => _carbsAgo = (_carbsAgo - 15).clamp(0, 120)),
                  onPlus: () => setState(() => _carbsAgo = (_carbsAgo + 15).clamp(0, 120)),
                ),
                StepRow(
                  label: 'Insulin with the carbs',
                  hint: _carbInsulinEdited
                      ? 'Changed by you (suggested ${fmtU(lim(calcCarbs.total))} U)'
                      : 'Suggested by the calculator${calcCarbs.total > bolusLimit ? ' (cut to the ${fmtU(bolusLimit)} U limit)' : ''}',
                  value: '${fmtU(carbInsulin)} U',
                  onMinus: () => setState(() {
                    _carbInsulin = ((carbInsulin - 0.05).clamp(0.0, bolusLimit) * 100).round() / 100;
                    _carbInsulinEdited = true;
                  }),
                  onPlus: () => setState(() {
                    _carbInsulin = ((carbInsulin + 0.05).clamp(0.0, bolusLimit) * 100).round() / 100;
                    _carbInsulinEdited = true;
                  }),
                  last: true,
                ),
                if (_carbInsulinEdited)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(onPressed: () => setState(() => _carbInsulinEdited = false), child: Text('Use the suggestion (${fmtU(lim(calcCarbs.total))} U)')),
                  ),
                _calcTile(calcCarbs),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => _sendCarbs(carbInsulin),
                  child: Text(carbInsulin > 0 ? 'Send ${_carbs.round()} g + ${fmtU(carbInsulin)} U to Loop' : 'Send ${_carbs.round()} g to Loop'),
                ),
              ]),
              _card('Bolus', [
                StepRow(
                  label: 'Bolus',
                  hint: '${_bolusEdited ? 'Changed by you' : 'Suggested by the calculator (correction − IOB)'} · limit ${fmtU(bolusLimit)} U'
                      '${loopMax != null ? ' (yours or Loop\'s maximum, the lower)' : ''}',
                  value: '${fmtU(bolus)} U',
                  onMinus: () => setState(() {
                    _bolus = ((bolus - 0.05).clamp(0.0, bolusLimit) * 100).round() / 100;
                    _bolusEdited = true;
                  }),
                  onPlus: () => setState(() {
                    _bolus = ((bolus + 0.05).clamp(0.0, bolusLimit) * 100).round() / 100;
                    _bolusEdited = true;
                  }),
                  last: true,
                ),
                Wrap(spacing: 6, children: [
                  for (final v in [0.25, 0.5, 1.0, 2.0])
                    if (v <= bolusLimit)
                      ActionChip(
                          label: Text('${fmtU(v)} U'),
                          onPressed: () => setState(() {
                                _bolus = v;
                                _bolusEdited = true;
                              })),
                  if (_bolusEdited) ActionChip(label: Text('Suggested ${fmtU(lim(calcBolus.total))} U'), onPressed: () => setState(() => _bolusEdited = false)),
                ]),
                _calcTile(calcBolus),
                const SizedBox(height: 8),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF3D7BF7)),
                  onPressed: bolus > 0 ? () => _sendBolus(bolus) : null,
                  child: Text(bolus > 0 ? 'Send ${fmtU(bolus)} U bolus to Loop' : 'No bolus suggested'),
                ),
              ]),
              if (_sending) const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
              const SizedBox(height: 12),
              _card('Settings', [
                if (allReady) ...checks,
                if (allReady) const SizedBox(height: 6),
                OutlinedButton.icon(onPressed: _settings, icon: const Icon(Icons.tune), label: const Text('Limits, name and command site')),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BolusCalcScreen())),
                  icon: const Icon(Icons.calculate_outlined),
                  label: const Text('Bolus calculator'),
                ),
              ]),
              const Text(
                'Remote commands must be turned on in Loop (Settings › Services › Nightscout › Remote Commands). '
                'Loop checks every command against its own limits and shows a notification on the Loop phone.',
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
            ]),
          );
        },
      ),
    );
  }
}
