import 'package:flutter/material.dart';

import '../common.dart';

class AlarmSettingsScreen extends StatelessWidget {
  const AlarmSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(title: 'Other alarms', builder: (_) => [
      Section(title: 'Missed readings', children: [
        setSwitch('On', 'noDataOn'),
        setInt('No reading for', 'noDataMin', step: 5, min: 10, max: 60, unit: 'min'),
      ]),
      Section(title: 'Predicted low', children: [
        setSwitch('On', 'predLowOn', hint: 'Uses the forecast from your loop; sounds like a yellow low'),
        setInt('Look ahead', 'predLowMin', step: 5, min: 10, max: 60, unit: 'min'),
      ]),
      Section(title: 'Loop and pump', children: [
        setSwitch('Loop not running', 'loopOn'),
        setInt('Loop quiet for', 'loopMin', step: 5, min: 10, max: 120, unit: 'min'),
        setSwitch('Insulin running low', 'reservoirOn'),
        setInt('Reservoir below', 'reservoirU', step: 5, min: 5, max: 80, unit: 'U'),
        setSwitch('Pump battery low', 'pumpBatOn'),
        setInt('Pump battery below', 'pumpBatPct', step: 5, min: 5, max: 50, unit: '%'),
      ]),
      Section(title: 'Gentle wake-up', children: [
        setSwitch('Wake gently', 'gentleOn', hint: 'Screen flashes first, then the sound starts'),
        setInt('Flash screen for', 'flashSec', step: 5, min: 0, max: 60, unit: 's'),
        setSwitch('Red zone skips gentle wake-up', 'urgentSkipsGentle'),
      ]),
      Section(title: 'Quiet hours', children: [
        setSwitch('On', 'quietOn', hint: 'Red zone and missed-reading alarms always sound'),
        setTime('From', 'quietFrom'),
        setTime('To', 'quietTo'),
        setChoice('During quiet hours', 'quietMode', const ['Yellow alarms muted', 'Half volume', 'Vibrate only']),
      ]),
      const Text(
        'Zone alarms (red and yellow, low and high) and their sounds are set in BG zones and in Alarm sounds & snooze.',
        style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
      ),
    ]);
  }
}
