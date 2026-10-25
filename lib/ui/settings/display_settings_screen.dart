import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../state/settings.dart';
import '../bg_chart.dart';
import '../common.dart';

/// Hours a graph button can show.
const _hourChoices = [1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 18, 24];

class DisplaySettingsScreen extends StatelessWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(title: 'Display & graph', builder: (_) {
      final s = app.settings;
      final buttons = List<int>.from(app.graphButtons);
      while (buttons.length < 5) {
        buttons.add(24);
      }

      void setButton(int i, int dir) {
        final cur = buttons[i];
        var k = _hourChoices.indexOf(cur);
        if (k < 0) k = 0;
        k = (k + dir).clamp(0, _hourChoices.length - 1);
        final list = List<int>.from(buttons);
        list[i] = _hourChoices[k];
        app.change((x) {
          x.set('graphButtons', list);
          if (!list.contains(x.integer('graphHours'))) x.set('graphHours', list[0]);
        });
      }

      // Top of the graph: auto, or a fixed value (stored in mg/dL).
      final topsMmol = [0.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0];
      final topsMg = [0.0, 180.0, 200.0, 240.0, 280.0, 320.0, 400.0];
      final tops = s.mmol ? topsMmol.map((v) => v * mgPerMmol).toList() : topsMg;
      final topLabels = s.mmol
          ? topsMmol.map((v) => v == 0 ? 'Auto' : v.toStringAsFixed(0)).toList()
          : topsMg.map((v) => v == 0 ? 'Auto' : v.toStringAsFixed(0)).toList();
      var topIndex = 0;
      for (var i = 0; i < tops.length; i++) {
        if ((tops[i] - s.number('graphTop')).abs() < 1) topIndex = i;
      }

      const scales = [0, 60, 70, 80, 90, 100, 115, 130, 150, 175, 200];
      final scaleIndex = scales.indexOf(s.integer('uiScale')).clamp(0, scales.length - 1);

      return [
        Section(title: 'Patient', children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: TextFormField(
              initialValue: s.str('patientName'),
              decoration: const InputDecoration(labelText: 'Name shown above the glucose (empty: none)'),
              onChanged: (v) => app.change((x) => x.set('patientName', v)),
            ),
          ),
        ]),
        Section(title: 'Units', children: [
          ChoiceRow(
            label: 'Glucose units',
            options: const ['mmol/L', 'mg/dL'],
            index: s.mmol ? 0 : 1,
            onChanged: (i) => app.change((x) => x.set('mmol', i == 0)),
          ),
        ]),
        Section(title: 'Buttons above the graph', children: [
          for (var i = 0; i < 5; i++)
            StepRow(
              label: 'Button ${i + 1}',
              value: '${buttons[i]} h',
              onMinus: () => setButton(i, -1),
              onPlus: () => setButton(i, 1),
            ),
          ChoiceRow(
            label: 'Selected when the app opens',
            options: [for (final h in buttons.take(5)) '$h hours'],
            index: buttons.indexOf(s.integer('graphHours')).clamp(0, 4),
            onChanged: (i) => app.change((x) => x.set('graphHours', buttons[i])),
          ),
          LinkRow(
            label: 'Back to 1, 2, 3, 6 and 12 hours',
            onTap: () => app.change((x) {
              x.set('graphButtons', [1, 2, 3, 6, 12]);
              x.set('graphHours', 3);
            }),
          ),
        ]),
        Section(title: 'Graph', children: [
          ChoiceRow(
            label: 'Top of graph',
            hint: 'Auto: just above your high line, higher when readings go above it',
            options: topLabels,
            index: topIndex,
            onChanged: (i) => app.change((x) => x.set('graphTop', tops[i])),
          ),
          setChoice('Graph height', 'graphFit', const ['Fit the screen on a computer', 'Always fit the screen', 'Fixed (set in Day view layout)'],
              hint: 'Fit: the graph uses the room left, so the whole page shows without scrolling'),
          ChoiceRow(
            label: 'Dot size',
            options: const ['Small', 'Medium', 'Large', 'Extra large'],
            index: s.integer('dotSize'),
            onChanged: (i) => app.change((x) => x.set('dotSize', i)),
          ),
          ...ttirSettings(),
          setSwitch('Phone on its side: split the screen', 'landSplit', hint: 'Values on the left, graph on the right'),
          setInt('Width of the values side', 'splitLeft', step: 5, min: 25, max: 70, unit: '%'),
          setChoice('Bottom bar (Live, Treat…)', 'navCompact', const ['Thin on a computer', 'Always thin', 'Always normal'],
              hint: 'Thin leaves more room for the graph'),
          ...graphGridSettings(),
          setSwitch('Prediction', 'showPrediction'),
          setSwitch('Basal on the graph', 'showBasal'),
          setSwitch('Treatments on the graph', 'showTreatments', hint: 'Boluses, carbs and SMBs'),
          setInt('Treatment size', 'treatSize', step: 10, min: 50, max: 300, unit: '%'),
          setChoice('Treatments placed', 'treatPlace', const ['At the top of the graph', 'On the glucose line']),
          ...smbSettings(),
        ]),
        Section(title: 'Brightness', children: [
          setSwitch('Dim the screen', 'dimOn', hint: 'Same as the brightness button on the main screen'),
          setInt('Darker by', 'dimPct', step: 10, min: 10, max: 90, unit: '%'),
        ]),
        Section(title: 'Screen size', children: [
          ChoiceRow(
            label: 'Size of everything',
            hint: 'Auto makes the app larger on a tablet',
            options: const ['Auto', '60%', '70%', '80%', '90%', '100%', '115%', '130%', '150%', '175%', '200%'],
            index: scaleIndex,
            onChanged: (i) => app.change((x) => x.set('uiScale', scales[i])),
          ),
          setChoice('Layout', 'screenMode', const ['Auto', 'Computer', 'Phone'],
              hint: 'Computer: one wide page that fits the screen (big glucose, cards on one line, graph filling the rest). '
                  'Auto picks Computer on a laptop or desktop in landscape'),
        ]),
        Section(title: 'Reports: time in range', children: [
          setMg('Range from', 'tirLo', min: 54, max: 140),
          setMg('Range to', 'tirHi', min: 120, max: 300),
        ]),
      ];
    });
  }
}
