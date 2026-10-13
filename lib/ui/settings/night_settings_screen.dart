import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../common.dart';
import 'layout_screen.dart';

class NightSettingsScreen extends StatelessWidget {
  const NightSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Night view & checklist',
      actions: [
        TextButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LayoutScreen())),
          child: const Text('Edit layout'),
        ),
      ],
      builder: (context) => [
        Section(title: 'Night view', children: [
          setInt('Brightness', 'nightBrightness', step: 5, min: 5, max: 100, unit: '%', hint: 'Low enough to glance at without waking up'),
          setSwitch('Keep screen awake', 'nightKeepAwake', hint: 'Leave the phone charging'),
          setChoice('Orientation', 'nightOrientation', const ['Auto', 'Portrait', 'Landscape']),
          setInt('Mark reading as old after', 'nightStaleMin', step: 1, min: 5, max: 30, unit: 'min'),
          setSwitch('Move text slowly', 'nightBurnIn', hint: 'Prevents screen burn-in'),
          LinkRow(label: 'Lines, sizes, colours and positions', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LayoutScreen()))),
        ]),
        Section(title: 'Schedule', children: [
          setSwitch('Open night view automatically', 'nightAutoOn', hint: 'When the app is open at this time'),
          setTime('At', 'nightFrom'),
        ]),
        Section(title: 'Before-sleep checklist', children: [
          setSwitch('Show checklist automatically', 'ckOn', hint: 'When the app is open at this time'),
          setTime('At', 'ckAt'),
          setInt('Insulin needed for the night', 'ckInsulinU', step: 5, min: 5, max: 100, unit: 'U'),
          setInt('Lowest OK pump battery', 'ckPumpBat', step: 5, min: 5, max: 80, unit: '%'),
          setInt('Sensor life', 'sensorDays', step: 1, min: 7, max: 15, unit: 'days'),
          setInt('Cannula life', 'siteHours', step: 12, min: 48, max: 96, unit: 'h'),
        ]),
        OutlinedButton(onPressed: app.openNight, child: const Text('Open night view now')),
      ],
    );
  }
}
