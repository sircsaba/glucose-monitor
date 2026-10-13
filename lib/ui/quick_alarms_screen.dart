import 'package:flutter/material.dart';

import '../logic/glucose.dart';
import '../state/app_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'settings/menu_screen.dart';

class QuickAlarmsScreen extends StatelessWidget {
  const QuickAlarmsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final s = app.settings;
        final r = app.range;
        final mmol = s.mmol;
        final rules = [
          'Below ${fmtBg(r.redLo, mmol)}',
          '${fmtBg(r.redLo, mmol)} to ${fmtBg(r.yelLo, mmol)}',
          '${fmtBg(r.yelHi, mmol)} to ${fmtBg(r.redHi, mmol)}',
          'Above ${fmtBg(r.redHi, mmol)}',
          'No data, loop, insulin, pump battery',
        ];
        final colors = [kRed, kYellow, kYellow, kRed, kMuted];
        final now = DateTime.now();
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Row(children: [
              const Expanded(child: Text('Alarms', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600))),
              TextButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MenuScreen())),
                child: const Text('All settings ›'),
              ),
            ]),
            const SizedBox(height: 4),
            Text('Now using the "${r.name}" range', style: const TextStyle(color: kMuted, fontSize: 13)),
            const SizedBox(height: 12),
            Section(children: [
              for (var i = 0; i < kSoundGroups.length; i++)
                RowBox(
                  last: i == kSoundGroups.length - 1,
                  child: Row(children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[i], shape: BoxShape.circle)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(kSoundGroups[i], style: const TextStyle(fontSize: 15)),
                        Text(rules[i], style: const TextStyle(color: kMuted, fontSize: 12)),
                      ]),
                    ),
                    Switch(
                      value: s.sounds[i].enabled,
                      onChanged: (v) => app.change((x) => x.sounds[i].enabled = v),
                    ),
                  ]),
                ),
            ]),
            Section(title: 'Snoozed now', children: [
              if (app.snoozes.isEmpty)
                const RowBox(last: true, child: Align(alignment: Alignment.centerLeft, child: Text('Nothing is snoozed', style: TextStyle(color: kMuted)))),
              for (final e in app.snoozes.entries)
                RowBox(
                  child: Row(children: [
                    Expanded(
                      child: Text('${alarmTitle(e.key)} · ${e.value.until.difference(now).inMinutes + 1} min left'),
                    ),
                    TextButton(onPressed: () => app.cancelSnooze(e.key), child: const Text('Wake again')),
                  ]),
                ),
            ]),
            Section(title: 'Try the alarms', children: [
              LinkRow(label: 'Test red low alarm', onTap: () => app.testAlarm(AlarmKind.redLow)),
              LinkRow(label: 'Test yellow low alarm', onTap: () => app.testAlarm(AlarmKind.yellowLow)),
              LinkRow(label: 'Test high alarm', onTap: () => app.testAlarm(AlarmKind.yellowHigh)),
            ]),
            const Text(
              'Alarms sound while the app is open. At night, leave it open in night view with the phone charging.',
              style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
            ),
          ],
        );
      },
    );
  }
}
