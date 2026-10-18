import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../data/nightscout.dart';
import '../logic/glucose.dart';
import '../logic/otp.dart';
import '../logic/profile.dart';
import '../logic/qr.dart';
import '../plus.dart';
import '../state/app_state.dart';
import '../state/settings.dart';
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

/// Loop remote control (Glucose Monitor Plus): overrides, carbs and boluses,
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
  const RemoteScreen({super.key});
  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  Totp? _totp;
  String? _savedSecret; // API secret remembered on this phone
  String? _cmdUrl; // another site for commands ('' = the connected site)
  String? _cmdSecret;
  double _carbs = 20;
  double _absorption = 3;
  int _carbsAgo = 0; // minutes
  double _bolus = 0.5;
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

  Future<void> _send(Map<String, dynamic> body, String done) async {
    final secret = await _secret();
    if (secret == null) return;
    setState(() => _sending = true);
    try {
      await _client.sendLoopCommand({
        ...body,
        'enteredBy': s.str('remoteName').isEmpty ? kAppName : s.str('remoteName'),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }, secret: secret.isEmpty ? null : secret);
      _snack('$done. Loop shows its own notification; the entry appears here within a minute or two.');
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
    await _send({
      'eventType': 'Temporary Override',
      'reason': p.name,
      'reasonDisplay': p.label,
      if (dur != null && dur > 0) 'duration': dur,
    }, 'Override sent');
  }

  Future<void> _cancelOverride() async {
    if (!await _confirm('Cancel the override?', 'Loop goes back to its normal settings.')) return;
    await _send({'eventType': 'Temporary Override Cancel'}, 'Cancel sent');
  }

  Future<void> _sendCarbs() async {
    if (_carbs > _maxCarbs) return _snack('More than your limit of ${_maxCarbs.round()} g (gear button)');
    final when = _carbsAgo == 0 ? 'now' : '$_carbsAgo min ago';
    if (!await _confirm('Send carbs to Loop?', '${_carbs.round()} g, absorption ${fmtU(_absorption)} h, eaten $when')) return;
    final otp = await _otp();
    if (otp == null) return;
    await _send({
      'eventType': 'Remote Carbs Entry',
      'remoteCarbs': _carbs.round(),
      'remoteAbsorption': _absorption,
      'otp': otp,
      'created_at': DateTime.now().subtract(Duration(minutes: _carbsAgo)).toUtc().toIso8601String(),
    }, 'Carbs sent');
  }

  Future<void> _sendBolus() async {
    final loopMax = _loop?.maxBolus;
    final limit = loopMax == null ? _maxBolus : math.min(_maxBolus, loopMax);
    if (_bolus > limit + 0.0001) return _snack('More than the limit of ${fmtU(limit)} U');
    if (!await _confirm('Send a bolus to Loop?', '${fmtU(_bolus)} U\n\nLoop checks it against its own limits before giving it.', danger: true)) return;
    final otp = await _otp();
    if (otp == null) return;
    await _send({'eventType': 'Remote Bolus Entry', 'remoteBolus': _bolus, 'otp': otp}, 'Bolus sent');
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
          final bolusLimit = loopMax == null ? _maxBolus : math.min(_maxBolus, loopMax);
          return AbsorbPointer(
            absorbing: _sending,
            child: ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 30), children: [
              _card('Ready?', [
                Text('Commands go through $_siteName, which sends them to the Loop phone with Apple\'s push service.',
                    style: const TextStyle(color: kMuted, fontSize: 12)),
                const SizedBox(height: 4),
                _check(loop?.deviceToken != null,
                    loop == null ? 'No Loop profile on this site yet' : (loop.deviceToken == null ? 'Loop profile without a device token' : 'Loop phone found (${loop.bundleId ?? 'Loop'})')),
                _check(hasSecret, hasSecret ? 'API secret available' : 'API secret: asked when you send', fix: hasSecret ? null : () => _secret().then((_) => setState(() {})), fixLabel: 'Enter'),
                _check(t != null, t != null ? 'One-time password set: ${t.code()} (${t.secondsLeft()} s)' : 'One-time password: needed for carbs and bolus',
                    fix: _setupOtp, fixLabel: t != null ? 'Change' : 'Set up'),
              ]),
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
                  last: true,
                ),
                const SizedBox(height: 8),
                FilledButton(onPressed: _sendCarbs, child: Text('Send ${_carbs.round()} g to Loop')),
              ]),
              _card('Bolus', [
                StepRow(
                  label: 'Bolus',
                  hint: 'Limit ${fmtU(bolusLimit)} U${loopMax != null ? ' (yours or Loop\'s maximum, the lower)' : ''}',
                  value: '${fmtU(_bolus)} U',
                  onMinus: () => setState(() => _bolus = ((_bolus - 0.05).clamp(0.05, bolusLimit) * 100).round() / 100),
                  onPlus: () => setState(() => _bolus = ((_bolus + 0.05).clamp(0.05, bolusLimit) * 100).round() / 100),
                  last: true,
                ),
                Wrap(spacing: 6, children: [
                  for (final v in [0.25, 0.5, 1.0, 2.0])
                    if (v <= bolusLimit) ActionChip(label: Text('${fmtU(v)} U'), onPressed: () => setState(() => _bolus = v)),
                ]),
                const SizedBox(height: 8),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF3D7BF7)),
                  onPressed: _sendBolus,
                  child: Text('Send ${fmtU(_bolus)} U bolus to Loop'),
                ),
              ]),
              if (_sending) const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
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
