import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../state/settings.dart';
import '../common.dart';

class SoundsScreen extends StatefulWidget {
  const SoundsScreen({super.key});
  @override
  State<SoundsScreen> createState() => _SoundsScreenState();
}

class _SoundsScreenState extends State<SoundsScreen> {
  int _group = 0;
  int _newPreset = 45;

  @override
  void dispose() {
    app.player.stopPreview();
    super.dispose();
  }

  String _mins(int m) => (m >= 60 && m % 60 == 0) ? '${m ~/ 60} h' : '$m min';

  @override
  Widget build(BuildContext context) {
    const groupColors = [Color(0xFFFF4D5A), Color(0xFFF2C94C), Color(0xFFF2C94C), Color(0xFFFF4D5A), kMuted];
    return Scaffold(
      appBar: AppBar(title: const Text('Alarm sounds & snooze')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final s = app.settings;
          final cfg = s.sounds[_group];
          void upd(void Function(SoundCfg c) f) => app.change((x) => f(x.sounds[_group]));

          Widget soundRow(int i) {
            final d = kSounds[i];
            final playing = app.player.previewing == i;
            return RowBox(
              child: Row(children: [
                Expanded(
                  child: InkWell(
                    onTap: () => upd((c) => c.sound = i),
                    child: Row(children: [
                      Icon(cfg.sound == i ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                          color: cfg.sound == i ? kAccent : kMuted),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(d.name),
                          Text(d.sub, style: const TextStyle(color: kMuted, fontSize: 12)),
                        ]),
                      ),
                    ]),
                  ),
                ),
                IconButton(
                  tooltip: playing ? 'Stop' : 'Play',
                  onPressed: () async {
                    await app.player.preview(i, cfg.volMode == 2 ? cfg.v1 : (cfg.volMode == 1 ? cfg.v2 : cfg.v1));
                    if (mounted) setState(() {});
                  },
                  icon: Icon(playing ? Icons.stop_circle_outlined : Icons.play_circle_outline, color: playing ? kAccent : kMuted),
                ),
              ]),
            );
          }

          final volRows = <Widget>[];
          if (cfg.volMode == 0) {
            volRows.add(StepRow(
              label: 'Volume',
              value: '${cfg.v1}%',
              onMinus: () => upd((c) => c.v1 = (c.v1 - 10).clamp(0, 100)),
              onPlus: () => upd((c) => c.v1 = (c.v1 + 10).clamp(0, 100)),
              last: true,
            ));
          } else {
            volRows.addAll([
              StepRow(
                label: cfg.volMode == 1 ? 'Start at' : 'Start loud at',
                value: '${cfg.v1}%',
                onMinus: () => upd((c) => c.v1 = (c.v1 - 10).clamp(0, 100)),
                onPlus: () => upd((c) => c.v1 = (c.v1 + 10).clamp(0, 100)),
              ),
              StepRow(
                label: cfg.volMode == 1 ? 'Rise to' : 'Fall to',
                value: '${cfg.v2}%',
                onMinus: () => upd((c) => c.v2 = (c.v2 - 10).clamp(0, 100)),
                onPlus: () => upd((c) => c.v2 = (c.v2 + 10).clamp(0, 100)),
              ),
              StepRow(
                label: 'Over',
                value: '${cfg.secs} s',
                onMinus: () => upd((c) => c.secs = (c.secs - 10).clamp(10, 600)),
                onPlus: () => upd((c) => c.secs = (c.secs + 10).clamp(10, 600)),
                last: true,
              ),
            ]);
          }

          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (var i = 0; i < kSoundGroups.length; i++)
                ChoiceChip(
                  avatar: CircleAvatar(radius: 5, backgroundColor: groupColors[i]),
                  label: Text(kSoundGroups[i]),
                  selected: _group == i,
                  onSelected: (_) => setState(() => _group = i),
                ),
            ]),
            const SizedBox(height: 14),
            Section(children: [
              SwitchRow(
                label: '${kSoundGroups[_group]} alarm',
                hint: _group == 4 ? 'No data, loop, insulin, pump battery' : null,
                value: cfg.enabled,
                onChanged: (v) => upd((c) => c.enabled = v),
              ),
              SwitchRow(label: 'Vibrate', value: cfg.vibrate, onChanged: (v) => upd((c) => c.vibrate = v)),
            ]),
            Section(title: 'Soft music', children: [for (var i = 0; i < kSounds.length; i++) if (kSounds[i].soft) soundRow(i)]),
            Section(title: 'Alarm sounds', children: [for (var i = 0; i < kSounds.length; i++) if (!kSounds[i].soft) soundRow(i)]),
            Section(title: 'Volume', children: [
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: Seg(
                  options: const ['Same', 'Louder', 'Softer'],
                  index: cfg.volMode,
                  onChanged: (m) => upd((c) {
                    c.volMode = m;
                    if (m == 1 && c.v2 <= c.v1) c.v2 = (c.v1 + 40).clamp(0, 100);
                    if (m == 2 && c.v2 >= c.v1) c.v2 = (c.v1 - 40).clamp(0, 100);
                  }),
                ),
              ),
              SizedBox(height: 60, child: CustomPaint(painter: _VolumePainter(cfg), size: Size.infinite)),
              ...volRows,
            ]),
            Section(title: 'Snooze buttons', padding: const EdgeInsets.fromLTRB(14, 12, 14, 0), children: [
              const Text('Quick buttons on the alarm screen (up to 6)', style: TextStyle(color: kMuted, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in s.snoozePresets)
                  InputChip(
                    label: Text(_mins(m)),
                    onDeleted: () => app.change((x) => x.snoozePresets.remove(m)),
                  ),
              ]),
              const SizedBox(height: 8),
              RowBox(
                child: Row(children: [
                  const Expanded(child: Text('New button')),
                  RoundButton('−', () => setState(() => _newPreset = (_newPreset - 5).clamp(5, 240))),
                  SizedBox(width: 70, child: Text('$_newPreset min', textAlign: TextAlign.center, style: kMono)),
                  RoundButton('+', () => setState(() => _newPreset = (_newPreset + 5).clamp(5, 240))),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: s.snoozePresets.length >= 6 || s.snoozePresets.contains(_newPreset)
                        ? null
                        : () => app.change((x) => x.snoozePresets
                          ..add(_newPreset)
                          ..sort()),
                    child: const Text('Add'),
                  ),
                ]),
              ),
              setSwitch('Allow a custom snooze', 'allowCustomSnooze', hint: 'Pick any number of minutes on the alarm screen'),
              setInt('Custom snooze starts at', 'customSnoozeDef', step: 5, min: 5, max: 240, unit: 'min'),
              setInt('"I\'m treating it" snoozes for', 'treatingSnoozeMin', step: 5, min: 5, max: 60, unit: 'min'),
              setInt('Longest snooze in red zone', 'maxRedSnooze', step: 5, min: 5, max: 60, unit: 'min', hint: 'Safety limit, whatever button is pressed'),
              setInt('Longest snooze for any alarm', 'maxSnoozeMin', step: 15, min: 15, max: 480, unit: 'min'),
              setSwitch('Smart snooze', 'smartSnooze', hint: 'Ends a snooze early if glucose keeps going the wrong way'),
              setSwitch('Wake again if it becomes urgent', 'wakeIfUrgent', hint: 'A snoozed yellow low that drops into the red zone'),
            ]),
          ]);
        },
      ),
    );
  }
}

class _VolumePainter extends CustomPainter {
  final SoundCfg cfg;
  _VolumePainter(this.cfg);
  @override
  void paint(Canvas canvas, Size size) {
    double y(int v) => size.height - 4 - v / 100 * (size.height - 8);
    final end = cfg.volMode == 0 ? cfg.v1 : cfg.v2;
    final rampX = cfg.volMode == 0 ? 0.0 : size.width * 0.7;
    final p = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, y(cfg.v1))
      ..lineTo(rampX, y(end))
      ..lineTo(size.width, y(end))
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = kAccent.withValues(alpha: 0.18));
    final line = Path()
      ..moveTo(0, y(cfg.v1))
      ..lineTo(rampX, y(end))
      ..lineTo(size.width, y(end));
    canvas.drawPath(
      line,
      Paint()
        ..color = kAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
