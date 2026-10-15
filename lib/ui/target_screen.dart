import 'dart:async';

import 'package:flutter/material.dart';

import '../logic/glucose.dart';
import '../state/app_state.dart';
import '../state/settings.dart';
import 'common.dart';

/// Target tab: a one-time alert when the glucose reaches a value, going up or
/// down. Shows the defaults (Settings › Target alert), which can be changed for
/// this time only, and an Activate button.
class TargetScreen extends StatefulWidget {
  const TargetScreen({super.key});
  @override
  State<TargetScreen> createState() => _TargetScreenState();
}

class _TargetScreenState extends State<TargetScreen> {
  late double _mg;
  bool? _rising; // null: decided from the current glucose
  late bool _sound;
  late int _soundIndex;
  late bool _vibrate;
  late bool _flash;
  late int _color;
  late int _timer;
  late int _timerAction;
  bool _touched = false; // changed here: keep these values; otherwise follow the defaults

  void _edit(VoidCallback f) {
    _touched = true;
    setState(f);
  }

  @override
  void initState() {
    super.initState();
    _loadDefaults();
  }

  void _loadDefaults() {
    final s = app.settings;
    _touched = false;
    _mg = s.number('tgtMg');
    _rising = null;
    _sound = s.flag('tgtSoundOn');
    _soundIndex = s.integer('tgtSound').clamp(0, kSounds.length - 1);
    _vibrate = s.flag('tgtVibrate');
    _flash = s.flag('tgtFlash');
    _color = s.integer('tgtColor');
    _timer = s.integer('tgtTimerMin');
    _timerAction = s.integer('tgtTimerAction');
  }

  bool _risingNow() {
    if (_rising != null) return _rising!;
    final l = app.latest;
    return l == null ? true : l.mg < _mg;
  }

  void _activate() {
    final now = DateTime.now();
    app.startTarget(TargetWatch(
      mg: _mg,
      rising: _risingNow(),
      started: now,
      expires: _timer > 0 ? now.add(Duration(minutes: _timer)) : null,
      timeUpAlert: _timerAction == 0,
      sound: _sound,
      soundIndex: _soundIndex,
      volume: app.settings.integer('tgtVolume'),
      vibrate: _vibrate,
      flash: _flash,
      color: _color,
    ));
    // Browsers only allow sound after a click: this one counts.
    app.player.unlock();
    setState(_loadDefaults);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        if (!_touched) _loadDefaults();
        final mmol = app.mmol;
        final l = app.latest;
        final w = app.target;
        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
          Row(children: [
            const Expanded(child: Text('Target alert', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600))),
            if (l != null)
              Text('Now ${fmtBg(l.mg, mmol)} ${arrowText(l.direction)}',
                  style: kMono.copyWith(fontSize: 18, color: app.isStale ? kMuted : app.colorFor(l.mg))),
          ]),
          const SizedBox(height: 4),
          const Text('One time: sound, vibrate and / or flash when the glucose reaches a value.',
              style: TextStyle(color: kMuted, fontSize: 13)),
          const SizedBox(height: 16),
          if (w != null) _activeCard(w, mmol) else ..._setup(mmol),
        ]);
      },
    );
  }

  Widget _activeCard(TargetWatch w, bool mmol) {
    final left = w.expires?.difference(DateTime.now());
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Color(w.color).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Color(w.color)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.flag, color: Color(w.color)),
          const SizedBox(width: 8),
          const Text('Active', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 10),
        Text(
          '${w.rising ? 'When it goes up to' : 'When it goes down to'} ${fmtBg(w.mg, mmol)} ${unitLabel(mmol)}',
          style: const TextStyle(fontSize: 20),
        ),
        const SizedBox(height: 6),
        Text(
          [if (w.sound) kSounds[w.soundIndex.clamp(0, kSounds.length - 1)].name, if (w.vibrate) 'vibrate', if (w.flash) 'flash']
              .join(' · '),
          style: const TextStyle(color: kMuted),
        ),
        if (left != null) ...[
          const SizedBox(height: 10),
          _Countdown(until: w.expires!, timeUpAlert: w.timeUpAlert),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton(onPressed: app.cancelTarget, child: const Text('Cancel')),
        ),
      ]),
    );
  }

  List<Widget> _setup(bool mmol) {
    final step = mmol ? mgPerMmol / 10 : 1.0;
    final rising = _risingNow();
    return [
      Section(children: [
        StepRow(
          label: 'Alert at',
          value: '${fmtBg(_mg, mmol)} ${mmol ? 'mmol' : 'mg'}',
          onMinus: () => _edit(() => _mg = (_mg - step).clamp(40.0, 400.0)),
          onPlus: () => _edit(() => _mg = (_mg + step).clamp(40.0, 400.0)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Seg(
              options: const ['Going up to it', 'Going down to it'],
              index: rising ? 0 : 1,
              onChanged: (i) => _edit(() => _rising = i == 0),
            ),
            const SizedBox(height: 6),
            Text(
              _rising == null ? 'Chosen from the current glucose. Tap to change.' : (rising ? 'At this value or higher.' : 'At this value or lower.'),
              style: const TextStyle(color: kMuted, fontSize: 12),
            ),
          ]),
        ),
        SwitchRow(label: 'Sound', value: _sound, onChanged: (v) => _edit(() => _sound = v)),
        if (_sound)
          ChoiceRow(
            label: 'Which sound',
            options: [for (final k in kSounds) k.name],
            index: _soundIndex,
            onChanged: (i) => _edit(() => _soundIndex = i),
          ),
        SwitchRow(label: 'Vibrate', hint: 'Phones only', value: _vibrate, onChanged: (v) => _edit(() => _vibrate = v)),
        SwitchRow(label: 'Flash the screen', value: _flash, onChanged: (v) => _edit(() => _flash = v)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Colour'),
            const SizedBox(height: 8),
            ColorPick(dot: 32, value: _color, onPick: (v) => _edit(() => _color = v)),
          ]),
        ),
        StepRow(
          label: 'Countdown',
          hint: _timer == 0 ? 'No time limit' : (_timerAction == 0 ? 'Then alerts you to take action' : 'Then cancels quietly'),
          value: _timer == 0 ? 'Off' : '$_timer min',
          onMinus: () => _edit(() => _timer = (_timer - 5).clamp(0, 240)),
          onPlus: () => _edit(() => _timer = (_timer + 5).clamp(0, 240)),
        ),
        if (_timer > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Seg(
              options: const ['Alert me to act', 'Just cancel'],
              index: _timerAction,
              onChanged: (i) => _edit(() => _timerAction = i),
            ),
          ),
      ]),
      SizedBox(
        height: 56,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Color(_color), foregroundColor: kBg),
          onPressed: app.latest == null ? null : _activate,
          icon: const Icon(Icons.flag),
          label: Text('Activate: ${rising ? '≥' : '≤'} ${fmtBg(_mg, mmol)}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        ),
      ),
      const SizedBox(height: 8),
      TextButton(onPressed: () => setState(_loadDefaults), child: const Text('Back to the defaults')),
      const Text('Defaults: Settings › Target alert.', style: TextStyle(color: kMuted, fontSize: 12), textAlign: TextAlign.center),
    ];
  }
}

class _Countdown extends StatefulWidget {
  final DateTime until;
  final bool timeUpAlert;
  const _Countdown({required this.until, required this.timeUpAlert});
  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.until.difference(DateTime.now());
    final s = d.isNegative ? 0 : d.inSeconds;
    final text = '${s ~/ 60}:${two(s % 60)}';
    return Text(
      '$text left${widget.timeUpAlert ? ', then an alert to take action' : ', then it cancels'}',
      style: kMono.copyWith(fontSize: 16),
    );
  }
}

/// Shown when a target alert goes off.
class TargetAlertScreen extends StatefulWidget {
  const TargetAlertScreen({super.key});
  @override
  State<TargetAlertScreen> createState() => _TargetAlertScreenState();
}

class _TargetAlertScreenState extends State<TargetAlertScreen> {
  Timer? _blink;
  bool _on = true;

  @override
  void initState() {
    super.initState();
    _blink = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (mounted) setState(() => _on = !_on);
    });
  }

  @override
  void dispose() {
    _blink?.cancel();
    super.dispose();
  }

  void _ok() {
    app.dismissTarget();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final hit = app.targetHit;
        if (hit == null) {
          return const Scaffold(backgroundColor: kBg, body: SizedBox.shrink());
        }
        final w = hit.watch;
        final mmol = app.mmol;
        final c = Color(w.color);
        final bg = w.flash ? (_on ? c : kBg) : c.withValues(alpha: 0.25);
        final fg = w.flash && _on ? kBg : kText;
        final l = app.latest;
        return Scaffold(
          backgroundColor: bg,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Icon(hit.reached ? Icons.flag : Icons.timer_off_outlined, size: 64, color: fg),
                const SizedBox(height: 16),
                Text(
                  hit.reached
                      ? 'Glucose reached ${fmtBg(w.mg, mmol)}'
                      : 'Time is up: ${fmtBg(w.mg, mmol)} not reached',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: fg),
                ),
                const SizedBox(height: 12),
                if (l != null)
                  Text(
                    'Now ${fmtBg(l.mg, mmol)} ${unitLabel(mmol)} ${arrowText(l.direction)}',
                    textAlign: TextAlign.center,
                    style: kMono.copyWith(fontSize: 22, color: fg),
                  ),
                if (!hit.reached)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Check and take action.', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: fg)),
                  ),
                const SizedBox(height: 40),
                SizedBox(
                  height: 64,
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: kText, foregroundColor: kBg),
                    onPressed: _ok,
                    child: const Text('OK', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// Settings › Target alert: the defaults shown on the Target tab.
class TargetSettingsScreen extends StatelessWidget {
  const TargetSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return SettingsPage(title: 'Target alert', builder: (context) {
      final s = app.settings;
      return [
        Section(title: 'Defaults', children: [
          setMg('Alert at', 'tgtMg', min: 40, max: 400, hint: 'Going up or down is chosen from the glucose when you activate it'),
          setSwitch('Sound', 'tgtSoundOn'),
          ChoiceRow(
            label: 'Which sound',
            options: [for (final k in kSounds) k.name],
            index: s.integer('tgtSound').clamp(0, kSounds.length - 1),
            onChanged: (i) => app.change((x) => x.set('tgtSound', i)),
          ),
          setInt('Volume', 'tgtVolume', step: 10, min: 10, max: 100, unit: '%'),
          setSwitch('Vibrate', 'tgtVibrate', hint: 'Phones only'),
          setSwitch('Flash the screen', 'tgtFlash'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Colour', style: TextStyle(fontSize: 15)),
              const SizedBox(height: 8),
              ColorPick(dot: 32, value: s.integer('tgtColor'), onPick: (v) => app.change((x) => x.set('tgtColor', v))),
            ]),
          ),
          setInt('Countdown', 'tgtTimerMin', step: 5, min: 0, max: 240, unit: 'min', hint: '0 = no time limit'),
          setChoice('When the countdown ends', 'tgtTimerAction', const ['Alert me to take action', 'Just cancel']),
        ]),
        OutlinedButton(
          onPressed: () => app.player.preview(s.integer('tgtSound'), s.integer('tgtVolume')),
          child: const Text('Play the sound'),
        ),
      ];
    });
  }
}
