import 'package:flutter/material.dart';

import '../../logic/glucose.dart';
import '../../state/app_state.dart';
import '../common.dart';

class AlarmSettingsScreen extends StatelessWidget {
  const AlarmSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => GroupedSettingsPage(
        title: 'Other alarms',
        groups: alarmGroups,
        bottom: (_) => const [
          Text(
            'Zone alarms (red and yellow, low and high) and their sounds are set in BG zones and in Alarm sounds & snooze.',
            style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
          ),
        ],
      );
}

String _on(String key, String detail) => app.settings.flag(key) ? 'On · $detail' : 'Off';

/// The groups of Other alarms (also searched from the Settings menu).
List<SettingsGroup> alarmGroups() {
  final s = app.settings;
  final t24 = s.flag('time24');
  return [
    SettingsGroup('Sound', icon: Icons.volume_up_outlined, summary: () => s.flag('muted') ? 'Alarm sounds muted' : 'Sounds on', rows: (_) => [
          setSwitch('Mute alarm sounds', 'muted', hint: 'Same as the bell button on the main screen: alarms still show on the screen and vibrate'),
        ]),
    SettingsGroup('Missed readings', icon: Icons.signal_wifi_off_outlined, summary: () => _on('noDataOn', 'after ${s.integer('noDataMin')} min'), rows: (_) => [
          setSwitch('On', 'noDataOn'),
          setInt('No reading for', 'noDataMin', step: 5, min: 10, max: 60, unit: 'min'),
        ]),
    SettingsGroup('Predicted low', icon: Icons.trending_down, summary: () => _on('predLowOn', '${s.integer('predLowMin')} min ahead'), rows: (_) => [
          setSwitch('On', 'predLowOn', hint: 'Uses the forecast from your loop; sounds like a yellow low'),
          setInt('Look ahead', 'predLowMin', step: 5, min: 10, max: 60, unit: 'min'),
        ]),
    SettingsGroup('Loop and pump', icon: Icons.loop, summary: () {
      final on = [if (s.flag('loopOn')) 'loop', if (s.flag('reservoirOn')) 'insulin', if (s.flag('pumpBatOn')) 'battery'];
      return on.isEmpty ? 'Off' : 'On: ${on.join(', ')}';
    }, rows: (_) => [
          setSwitch('Loop not running', 'loopOn'),
          setInt('Loop quiet for', 'loopMin', step: 5, min: 10, max: 120, unit: 'min'),
          setSwitch('Insulin running low', 'reservoirOn'),
          setInt('Reservoir below', 'reservoirU', step: 5, min: 5, max: 80, unit: 'U'),
          setSwitch('Pump battery low', 'pumpBatOn'),
          setInt('Pump battery below', 'pumpBatPct', step: 5, min: 5, max: 50, unit: '%'),
        ]),
    SettingsGroup('Gentle wake-up', icon: Icons.wb_twilight, summary: () => _on('gentleOn', 'flash ${s.integer('flashSec')} s'), rows: (_) => [
          setSwitch('Wake gently', 'gentleOn', hint: 'Screen flashes first, then the sound starts'),
          setInt('Flash screen for', 'flashSec', step: 5, min: 0, max: 60, unit: 's'),
          setSwitch('Red zone skips gentle wake-up', 'urgentSkipsGentle'),
        ]),
    SettingsGroup('Quiet hours', icon: Icons.bedtime_outlined,
        summary: () => _on('quietOn', '${fmtMinutesOfDay(s.integer('quietFrom'), t24)}–${fmtMinutesOfDay(s.integer('quietTo'), t24)}'),
        rows: (_) => [
              setSwitch('On', 'quietOn', hint: 'Red zone and missed-reading alarms always sound'),
              setTime('From', 'quietFrom'),
              setTime('To', 'quietTo'),
              setChoice('During quiet hours', 'quietMode', const ['Yellow alarms muted', 'Half volume', 'Vibrate only']),
            ]),
  ];
}
