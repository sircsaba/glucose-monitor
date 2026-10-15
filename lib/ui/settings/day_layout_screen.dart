import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../state/settings.dart';
import '../bg_chart.dart';
import '../common.dart';
import '../home_screen.dart';

/// Edits the main (day) screen: every element's size, colour, alignment,
/// width, line and order. The preview at the top uses your live data; tap an
/// element in it to select it.
class DayLayoutScreen extends StatefulWidget {
  const DayLayoutScreen({super.key});
  @override
  State<DayLayoutScreen> createState() => _DayLayoutScreenState();
}

class _DayLayoutScreenState extends State<DayLayoutScreen> {
  String _sel = 'bg';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Day view layout'), actions: [
        TextButton(
          onPressed: () => app.change((s) {
            s.day = Settings.defaultDay();
            s.set('dayCustom', false);
            s.set('dayArrow', true);
            s.set('dayBgDelta', true);
          }),
          child: const Text('Reset'),
        ),
      ]),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final s = app.settings;
          final screen = MediaQuery.of(context).size;
          final wide = DayView.isWide(context);
          final list = s.dayFor(wide);
          var idx = list.indexWhere((l) => l.id == _sel);
          if (idx < 0) idx = 0;
          final cur = list[idx];
          final isGraph = cur.id == 'graph';
          // The first change saves the layout shown (phone or wide default) as yours.
          void own(Settings x) {
            if (!x.flag('dayCustom')) {
              x.day = Settings.defaultDay(compact: wide, big: wide);
              x.set('dayCustom', true);
            }
          }

          void upd(void Function(LineCfg c) f) => app.change((x) {
                own(x);
                f(x.day.firstWhere((l) => l.id == cur.id));
              });
          void move(int dir) => app.change((x) {
                own(x);
                final i = x.day.indexWhere((l) => l.id == cur.id);
                final j = i + dir;
                if (i < 0 || j < 0 || j >= x.day.length) return;
                final t = x.day[i];
                x.day[i] = x.day[j];
                x.day[j] = t;
              });
          final step = cur.size >= 100 ? 10.0 : (cur.size >= 40 ? 4.0 : 1.0);

          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
            const Text('Tap an element in the preview, or pick it below.', style: TextStyle(color: kMuted, fontSize: 13)),
            const SizedBox(height: 10),
            // Preview with your live data, in the shape of this screen.
            Center(
              child: Builder(builder: (context) {
                final frameW = wide ? (screen.width - 32).clamp(320.0, 1100.0) : 320.0;
                final innerW = wide ? 1300.0 : 390.0;
                return Container(
                  width: frameW,
                  padding: const EdgeInsets.fromLTRB(8, 14, 8, 14),
                  decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(wide ? 14 : 30), border: Border.all(color: kLine, width: 6)),
                  child: ClipRect(
                    child: SizedBox(
                      height: wide ? frameW * 0.5 : 560,
                      child: FittedBox(
                        fit: BoxFit.fitWidth,
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: innerW,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: DayView(preview: true, wide: wide, highlight: _sel, onSelect: (id) => setState(() => _sel = id)),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 8),
            Text(
              wide
                  ? 'Wide screen: the preview is drawn at computer width.'
                  : 'Phone screen.',
              style: const TextStyle(color: kMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Section(title: 'Start from', padding: const EdgeInsets.all(12), children: [
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => app.change((x) {
                      x.day = Settings.defaultDay();
                      x.set('dayCustom', true);
                    }),
                    child: const Text('Original layout', textAlign: TextAlign.center),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => app.change((x) {
                      x.day = Settings.defaultDay(compact: true, big: wide);
                      x.set('dayCustom', true);
                    }),
                    child: const Text('Compact: one line, big BG', textAlign: TextAlign.center),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              const Text(
                'Original: labels above the values, as on the phone. Compact: IOB, COB, basal, reservoir and pump '
                'battery on one line with the name beside the value, the clock left of a bigger glucose value. '
                'Then change anything below.',
                style: TextStyle(color: kMuted, fontSize: 12, height: 1.4),
              ),
            ]),
            const SizedBox(height: 16),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final l in list)
                ChoiceChip(
                  label: Text(kDayNames[l.id] ?? l.id, style: TextStyle(color: l.show ? null : kMuted)),
                  selected: l.id == _sel,
                  onSelected: (_) => setState(() => _sel = l.id),
                ),
            ]),
            const SizedBox(height: 14),
            Section(title: kDayNames[cur.id], children: [
              SwitchRow(label: 'Show', value: cur.show, onChanged: (v) => upd((c) => c.show = v)),
              if (cur.id == 'bg') ...[
                setSwitch('Trend arrow next to the value', 'dayArrow'),
                setSwitch('Change and units next to the value', 'dayBgDelta'),
              ],
              StepRow(
                label: isGraph ? 'Graph height' : 'Size',
                value: '${cur.size.round()} px',
                onMinus: () => upd((c) => c.size = (c.size - step).clamp(isGraph ? 120.0 : 8.0, isGraph ? 600.0 : 260.0)),
                onPlus: () => upd((c) => c.size = (c.size + step).clamp(isGraph ? 120.0 : 8.0, isGraph ? 600.0 : 260.0)),
              ),
              if (!isGraph) ...[
                SwitchRow(
                  label: 'On the same line as the element before',
                  hint: 'Elements on one line share its width',
                  value: cur.join,
                  onChanged: (v) => upd((c) => c.join = v),
                ),
                StepRow(
                  label: 'Width on its line',
                  hint: 'Share of the line compared with the others on it',
                  value: '${cur.flex}',
                  onMinus: () => upd((c) => c.flex = (c.flex - 1).clamp(1, 12)),
                  onPlus: () => upd((c) => c.flex = (c.flex + 1).clamp(1, 12)),
                ),
                SwitchRow(label: 'On a card', value: cur.box, onChanged: (v) => upd((c) => c.box = v)),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Text('Colour'),
                    const SizedBox(height: 8),
                    ColorPick(
                      value: cur.color,
                      zoneSelected: cur.zoneColor,
                      onZone: () => upd((c) => c.zoneColor = true),
                      onPick: (v) => upd((c) {
                        c.zoneColor = false;
                        c.color = v;
                      }),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      cur.zoneColor
                          ? 'First circle: follows the zone colour (green, yellow or red) of the current time range.'
                          : 'Always this colour.',
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
                SwitchRow(label: 'Bold', value: cur.bold, onChanged: (v) => upd((c) => c.bold = v)),
              ],
              RowBox(
                child: Row(children: [
                  const Expanded(child: Text('Position', style: TextStyle(fontSize: 15))),
                  OutlinedButton(onPressed: () => move(-1), child: const Text('Earlier')),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: () => move(1), child: const Text('Later')),
                ]),
              ),
              StepRow(
                label: 'Space above',
                value: '${cur.space.round()} px',
                last: !isGraph,
                onMinus: () => upd((c) => c.space = (c.space - 2).clamp(0.0, 80.0)),
                onPlus: () => upd((c) => c.space = (c.space + 2).clamp(0.0, 80.0)),
              ),
              if (isGraph) ...[
                setChoice('Graph height', 'graphFit', const ['Fit the screen on a computer', 'Always fit the screen', 'Fixed (Graph height above)'],
                    hint: 'Fit: the graph uses the room left, so the whole page shows without scrolling'),
                ...graphGridSettings(),
                setSwitch('Treatments on the graph', 'showTreatments', hint: 'Boluses and carbs'),
                setInt('Treatment size', 'treatSize', step: 10, min: 50, max: 300, unit: '%'),
                setChoice('Treatments placed', 'treatPlace', const ['At the top of the graph', 'On the glucose line']),
                setSwitch('Prediction', 'showPrediction'),
                setSwitch('Temp basal under graph', 'showBasal'),
                setChoice('Dot size', 'dotSize', const ['Small', 'Medium', 'Large']),
              ],
            ]),
            const Text(
              'Each phone, tablet and browser keeps its own layout. '
              'Zone colours come from BG zones & time ranges, where each range can have its own colours. '
              'The night and settings buttons always stay at the end of the first line.',
              style: TextStyle(color: kMuted, fontSize: 12, height: 1.45),
            ),
          ]);
        },
      ),
    );
  }
}
