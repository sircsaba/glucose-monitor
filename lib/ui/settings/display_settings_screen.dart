import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../common.dart';

class DisplaySettingsScreen extends StatelessWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const hours = [3, 6, 12, 24];
    return SettingsPage(title: 'Display & graph', builder: (_) {
      final s = app.settings;
      return [
        Section(title: 'Units', children: [
          ChoiceRow(
            label: 'Glucose units',
            options: const ['mmol/L', 'mg/dL'],
            index: s.mmol ? 0 : 1,
            onChanged: (i) => app.change((x) => x.set('mmol', i == 0)),
          ),
        ]),
        Section(title: 'Graph', children: [
          ChoiceRow(
            label: 'Default length',
            options: const ['3 hours', '6 hours', '12 hours', '24 hours'],
            index: hours.indexOf(s.integer('graphHours')).clamp(0, 3),
            onChanged: (i) => app.change((x) => x.set('graphHours', hours[i])),
          ),
          setSwitch('Prediction', 'showPrediction'),
          setSwitch('Temp basal under graph', 'showBasal'),
          setSwitch('Treatment markers', 'showTreatments'),
        ]),
        Section(title: 'Reports: time in range', children: [
          setMg('Range from', 'tirLo', min: 54, max: 140),
          setMg('Range to', 'tirHi', min: 120, max: 300),
        ]),
      ];
    });
  }
}
