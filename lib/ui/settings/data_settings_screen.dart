import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';
import '../common.dart';
import '../connect_screen.dart';

class DataSettingsScreen extends StatelessWidget {
  const DataSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const refresh = [60, 120, 300];
    return SettingsPage(title: 'Data & general', builder: (context) {
      final s = app.settings;
      return [
        Section(title: 'Nightscout site', children: [
          LinkRow(
            label: s.str('nsUrl'),
            hint: '${s.flag('apiSecret') ? 'API secret' : 'Access token'} · tap to change',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectScreen(fromSettings: true))),
          ),
          ChoiceRow(
            label: 'Check for new data every',
            options: const ['1 min', '2 min', '5 min'],
            index: refresh.indexOf(s.integer('refreshSec')).clamp(0, 2),
            onChanged: (i) {
              app.change((x) => x.set('refreshSec', refresh[i]));
              app.restartTimers();
            },
          ),
          setSwitch('Allow logging treatments', 'allowTreatments'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: TextFormField(
              initialValue: s.str('enteredBy'),
              decoration: const InputDecoration(labelText: 'Entered by (name saved with treatments)'),
              onChanged: (v) => app.change((x) => x.set('enteredBy', v)),
            ),
          ),
        ]),
        Section(title: 'General', children: [
          ChoiceRow(
            label: 'Time format',
            options: const ['24 h', '12 h'],
            index: s.flag('time24') ? 0 : 1,
            onChanged: (i) => app.change((x) => x.set('time24', i == 0)),
          ),
        ]),
        Section(title: 'Backup', children: [
          LinkRow(
            label: 'Copy settings',
            hint: 'Copies every setting as text, to paste into another phone',
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: app.exportSettings()));
              if (context.mounted) toast(context, 'Settings copied');
            },
          ),
          LinkRow(
            label: 'Paste settings',
            hint: 'Replaces these settings with copied ones',
            onTap: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              final ok = app.importSettings(data?.text ?? '');
              if (context.mounted) toast(context, ok ? 'Settings pasted' : 'The clipboard has no copied settings');
            },
          ),
          LinkRow(
            label: 'Reset all settings',
            hint: 'Keeps your site and token',
            onTap: () async {
              final yes = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Reset all settings?'),
                  content: const Text('Zones, sounds, snooze buttons, night layout and alarms go back to their defaults.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
                  ],
                ),
              );
              if (yes == true) app.resetAll();
            },
          ),
        ]),
        const Text(
          'For information only. Always check a meter or sensor before making treatment decisions.',
          style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
        ),
      ];
    });
  }
}
