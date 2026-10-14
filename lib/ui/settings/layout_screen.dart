import 'package:flutter/material.dart';

import '../../logic/glucose.dart';
import '../../state/app_state.dart';
import '../../state/settings.dart';
import '../common.dart';
import '../night_screen.dart';


class LayoutScreen extends StatefulWidget {
  const LayoutScreen({super.key});
  @override
  State<LayoutScreen> createState() => _LayoutScreenState();
}

class _LayoutScreenState extends State<LayoutScreen> {
  String _sel = 'bg';
  int _test = 0;

  static const _tests = [
    PreviewValues(112, 'Flat', 2, kGreen),
    PreviewValues(205, 'FortyFiveUp', 7, kYellow),
    PreviewValues(58, 'SingleDown', -5, kRed),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Night view layout'), actions: [
        TextButton(
          onPressed: () => app.change((s) {
            s.lines = Settings.defaultLines();
            s.set('nightBlockPos', 1);
            s.set('nightArrow', true);
          }),
          child: const Text('Reset'),
        ),
      ]),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final s = app.settings;
          final idx = s.lines.indexWhere((l) => l.id == _sel);
          final cur = s.lines[idx < 0 ? 0 : idx];
          void upd(void Function(LineCfg c) f) => app.change((x) => f(x.lines.firstWhere((l) => l.id == cur.id)));
          void move(int dir) => app.change((x) {
                final i = x.lines.indexWhere((l) => l.id == cur.id);
                final j = i + dir;
                if (i < 0 || j < 0 || j >= x.lines.length) return;
                final t = x.lines[i];
                x.lines[i] = x.lines[j];
                x.lines[j] = t;
              });
          final step = cur.size >= 60 ? 10.0 : 2.0;

          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
            Row(children: [
              const Text('Preview as', style: TextStyle(color: kMuted, fontSize: 13)),
              const SizedBox(width: 8),
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    avatar: CircleAvatar(radius: 5, backgroundColor: _tests[i].color),
                    label: Text(['Green', 'Yellow', 'Red'][i]),
                    selected: _test == i,
                    onSelected: (_) => setState(() => _test = i),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 300,
                height: 620,
                padding: const EdgeInsets.fromLTRB(18, 34, 18, 34),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(34),
                  border: Border.all(color: kLine, width: 6),
                ),
                child: ClipRect(
                  child: Opacity(
                    opacity: (s.integer('nightBrightness') / 100.0).clamp(0.35, 1.0),
                    child: NightView(scale: 300 / 390, preview: _tests[_test], highlight: _sel),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Choose a line to change', style: TextStyle(color: kMuted, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final l in s.lines)
                ChoiceChip(
                  label: Text(kLineNames[l.id] ?? l.id, style: TextStyle(color: l.show ? null : kMuted)),
                  selected: l.id == _sel,
                  onSelected: (_) => setState(() => _sel = l.id),
                ),
            ]),
            const SizedBox(height: 14),
            Section(children: [
              SwitchRow(label: 'Show "${kLineNames[cur.id]}"', value: cur.show, onChanged: (v) => upd((c) => c.show = v)),
              if (cur.id == 'bg') setSwitch('Trend arrow next to value', 'nightArrow'),
              StepRow(
                label: cur.id == 'graph' ? 'Height' : 'Text size',
                value: '${cur.size.round()} px',
                onMinus: () => upd((c) => c.size = (c.size - step).clamp(10.0, 260.0)),
                onPlus: () => upd((c) => c.size = (c.size + step).clamp(10.0, 260.0)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Colour'),
                  const SizedBox(height: 8),
                  Seg(
                    options: const ['By zone colour', 'Always one colour'],
                    index: cur.zoneColor ? 0 : 1,
                    onChanged: (i) => upd((c) => c.zoneColor = i == 0),
                  ),
                  const SizedBox(height: 10),
                  ColorPick(
                    value: cur.color,
                    zoneSelected: cur.zoneColor,
                    onZone: () => upd((c) => c.zoneColor = true),
                    onPick: (v) => upd((c) {
                      c.zoneColor = false;
                      c.color = v;
                    }),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    cur.zoneColor
                        ? 'Follows the zone: green, yellow or red. Tap a colour to always use one colour.'
                        : 'Always this colour, whatever the zone.',
                    style: const TextStyle(color: kMuted, fontSize: 12),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Alignment'),
                  const SizedBox(height: 8),
                  Seg(
                    options: const ['Left', 'Centre', 'Right'],
                    index: ['left', 'center', 'right'].indexOf(cur.align).clamp(0, 2),
                    onChanged: (i) => upd((c) => c.align = ['left', 'center', 'right'][i]),
                  ),
                ]),
              ),
              RowBox(
                child: Row(children: [
                  const Expanded(child: Text('Position')),
                  OutlinedButton(onPressed: () => move(-1), child: const Text('Move up')),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: () => move(1), child: const Text('Move down')),
                ]),
              ),
              StepRow(
                label: 'Space above',
                value: '${cur.space.round()} px',
                onMinus: () => upd((c) => c.space = (c.space - 4).clamp(0.0, 160.0)),
                onPlus: () => upd((c) => c.space = (c.space + 4).clamp(0.0, 160.0)),
              ),
              SwitchRow(label: 'Bold', value: cur.bold, onChanged: (v) => upd((c) => c.bold = v)),
            ]),
            Section(title: 'Whole screen', padding: const EdgeInsets.all(14), children: [
              const Text('All lines sit at the'),
              const SizedBox(height: 8),
              Seg(
                options: const ['Top', 'Middle', 'Bottom'],
                index: s.integer('nightBlockPos'),
                onChanged: (i) => app.change((x) => x.set('nightBlockPos', i)),
              ),
              const SizedBox(height: 8),
              const Text(
                'Zone colours come from BG zones & time ranges. In landscape the glucose value sits on the left and the other lines on the right.',
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
            ]),
          ]);
        },
      ),
    );
  }
}
