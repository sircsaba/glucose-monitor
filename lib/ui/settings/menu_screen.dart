import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../checklist_screen.dart';
import '../common.dart';
import '../logs_screen.dart';
import '../treatment_log_screen.dart';
import '../target_screen.dart';
import 'alarm_settings_screen.dart';
import 'data_settings_screen.dart';
import 'day_layout_screen.dart';
import 'display_settings_screen.dart';
import 'layout_screen.dart';
import 'night_settings_screen.dart';
import 'sounds_screen.dart';
import 'zones_screen.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});
  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    List<Widget> links() => [
        LinkRow(label: 'BG zones & time ranges', hint: 'Red, yellow and green limits for each time range', onTap: () => go(const ZonesScreen())),
        LinkRow(label: 'Alarm sounds & snooze', hint: 'Soft music, volume over time, snooze buttons', onTap: () => go(const SoundsScreen())),
        LinkRow(label: 'Day view layout', hint: 'Size, colour, line and position of everything on the main screen', onTap: () => go(const DayLayoutScreen())),
        LinkRow(label: 'Night view layout', hint: 'Size, colour and position of each line', onTap: () => go(const LayoutScreen())),
        LinkRow(label: 'Night view & checklist', hint: 'Brightness, schedule, before-sleep checks', onTap: () => go(const NightSettingsScreen())),
        LinkRow(label: 'Before-sleep checklist', hint: 'Run the checks now', onTap: () => go(const ChecklistScreen())),
        LinkRow(label: 'Target alert', hint: 'Defaults for the Target button: value, sound, vibrate, flash, colour, countdown', onTap: () => go(const TargetSettingsScreen())),
        LinkRow(label: 'Other alarms', hint: 'No data, low predicted, loop, pump, gentle wake-up, quiet hours', onTap: () => go(const AlarmSettingsScreen())),
        LinkRow(label: 'Logs', hint: 'Each reading, heartbeat push and loop run, with the time between them', onTap: () => go(const LogsScreen())),
        LinkRow(label: 'Treatment log', hint: 'Carbs, boluses, SMB, temp basals, overrides: filter and export', onTap: () => go(const TreatmentLogScreen())),
        LinkRow(label: 'Display & graph', hint: 'Units, graph and its markers, brightness, screen saver, reports', onTap: () => go(const DisplaySettingsScreen())),
        LinkRow(label: 'Data & general', hint: 'Site, refresh, time format, backup', onTap: () => go(const DataSettingsScreen())),
        LinkRow(label: 'Screen saver', hint: 'Glucose moving on a black screen, alarms quiet: button or every day at a set time', onTap: () => screenSaverGroup().open(context)),
      ];
    return SettingsPage(title: 'Settings', builder: (c) => [
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextField(
          controller: _search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search settings',
            isDense: true,
            suffixIcon: _q.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _search.clear();
                      _q = '';
                    }),
                  ),
          ),
          onChanged: (v) => setState(() => _q = v.trim()),
        ),
      ),
      if (_q.isNotEmpty) ...searchSettings(c, _q, links())
      else ...[
      Material(
        color: const Color(0xFF1A1420),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFF3A2A3A))),
        child: ListTile(
          leading: const Icon(Icons.bedtime_outlined, color: Color(0xFFE0353F)),
          title: const Text('Open night view', style: TextStyle(fontWeight: FontWeight.w600)),
          trailing: const Icon(Icons.chevron_right, color: kMuted),
          onTap: app.openNight,
        ),
      ),
      const SizedBox(height: 16),
      Section(children: links()),
      const Text(
        'Every value here is saved on the phone. Use Data & general › Copy settings to move them to another phone.',
        style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
      ),
      if (const String.fromEnvironment('BUILD').isNotEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Version ${String.fromEnvironment('BUILD')}', style: TextStyle(color: kMuted, fontSize: 12)),
        ),
      ],
    ]);
  }
}

/// Every setting whose name or note has all the words searched, with where it
/// lives. The rows found work right here (switch, change, open).
List<Widget> searchSettings(BuildContext context, String query, List<Widget> menuLinks) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  bool hit(String text) {
    final t = text.toLowerCase();
    return words.every(t.contains);
  }

  final found = <String, List<Widget>>{};
  void add(String where, Widget w) => (found[where] ??= []).add(w);
  void walk(String where, List<Widget> rows) {
    for (final w in rows) {
      if (w is Section) {
        walk(where, w.children);
        continue;
      }
      if (w is GroupRow) {
        final g = w.group;
        if (hit('${g.title} ${g.hint ?? ''}')) add(where, w);
        List<Widget> inner;
        try {
          inner = g.rows(context);
        } catch (_) {
          inner = const [];
        }
        walk('$where › ${g.title}', inner);
        continue;
      }
      final t = settingRowText(w);
      if (t != null && hit('${t.$1} ${t.$2}')) add(where, w);
    }
  }

  for (final l in menuLinks) {
    final t = settingRowText(l);
    if (t != null && hit('${t.$1} ${t.$2}')) add('Settings', l);
  }
  for (final (menu, groups) in [
    ('Display & graph', displayGroups()),
    ('Other alarms', alarmGroups()),
    ('Night view & checklist', nightGroups()),
    ('Data & general', dataGroups()),
  ]) {
    walk(menu, [for (final g in groups) GroupRow(g)]);
  }
  if (found.isEmpty) {
    return [const Padding(padding: EdgeInsets.all(12), child: Text('No setting with these words.', style: TextStyle(color: kMuted)))];
  }
  return [for (final e in found.entries) Section(title: e.key, children: e.value)];
}
