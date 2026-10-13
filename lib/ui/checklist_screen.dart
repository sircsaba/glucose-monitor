import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';

import '../logic/glucose.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'settings/night_settings_screen.dart';

enum _St { ok, fix, info }

class _Item {
  final String title;
  final String detail;
  final _St st;
  _Item(this.title, this.detail, this.st);
}

class ChecklistScreen extends StatefulWidget {
  const ChecklistScreen({super.key});
  @override
  State<ChecklistScreen> createState() => _ChecklistScreenState();
}

class _ChecklistScreenState extends State<ChecklistScreen> {
  final Battery _battery = Battery();
  int? _level;
  BatteryState? _state;
  bool _soundConfirmed = false;
  DateTime _checked = DateTime.now();

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      if (!mounted) return;
      setState(() {
        _level = level;
        _state = state;
        _checked = DateTime.now();
      });
    } catch (_) {}
    await app.refresh();
  }

  List<_Item> _items() {
    final s = app.settings;
    final d = app.device;
    final now = DateTime.now();
    final items = <_Item>[];
    final charging = _state == BatteryState.charging || _state == BatteryState.full;
    items.add(_Item(
      'This phone is charging',
      _level == null ? 'Checking…' : 'Battery $_level%${charging ? '' : ', plug it in'}',
      charging ? _St.ok : _St.fix,
    ));
    items.add(_Item(
      'Sound is on and loud',
      _soundConfirmed ? 'Confirmed' : 'Ringer switch off silent, volume up, Focus / Do Not Disturb off',
      _soundConfirmed ? _St.ok : _St.fix,
    ));
    final res = d?.reservoir;
    final need = s.integer('ckInsulinU');
    items.add(_Item(
      'Enough insulin for the night',
      res == null ? 'Pump did not report its reservoir' : '${res.round()} U in pump, need $need U',
      res == null ? _St.info : (res >= need ? _St.ok : _St.fix),
    ));
    final pb = d?.pumpBattery;
    items.add(_Item(
      'Pump battery',
      pb == null ? 'Pump did not report its battery' : '$pb%, lowest OK is ${s.integer('ckPumpBat')}%',
      pb == null ? _St.info : (pb >= s.integer('ckPumpBat') ? _St.ok : _St.fix),
    ));
    final lt = d?.loopTime;
    final loopOk = lt != null && now.difference(lt).inMinutes < s.integer('loopMin');
    items.add(_Item('Loop is running', lt == null ? 'No loop status on the site' : 'Last run ${fmtAgo(now.difference(lt))}', loopOk ? _St.ok : _St.fix));
    final age = app.age;
    items.add(_Item(
      'Sensor readings arriving',
      age == null ? 'No readings' : 'Last reading ${fmtAgo(age)}',
      (age != null && age.inMinutes < 10) ? _St.ok : _St.fix,
    ));
    final r = activeRange(s.ranges, DateTime(now.year, now.month, now.day, 2));
    double? minPred;
    for (final line in d?.predLines ?? const <List<double>>[]) {
      for (final v in line) {
        if (minPred == null || v < minPred) minPred = v;
      }
    }
    if (minPred != null) {
      items.add(_Item(
        'No low predicted',
        'Lowest forecast ${fmtBg(minPred, s.mmol)} (night yellow starts at ${fmtBg(r.yelLo, s.mmol)})',
        minPred >= r.yelLo ? _St.ok : _St.fix,
      ));
    }
    if (app.sensorStart != null) {
      final ends = app.sensorStart!.add(Duration(days: s.integer('sensorDays')));
      final left = ends.difference(now);
      items.add(_Item(
        left.inHours < 24 ? 'Sensor change due soon' : 'Sensor OK',
        left.isNegative ? 'Past its ${s.integer('sensorDays')}-day life' : 'Ends in ${fmtAge(left)}',
        left.inHours < 24 ? _St.info : _St.ok,
      ));
    }
    if (app.siteChange != null) {
      final ends = app.siteChange!.add(Duration(hours: s.integer('siteHours')));
      final left = ends.difference(now);
      items.add(_Item(
        left.inHours < 24 ? 'Cannula change due soon' : 'Cannula OK',
        left.isNegative ? 'Past its ${s.integer('siteHours')} h' : 'Due in ${fmtAge(left)}',
        left.inHours < 24 ? _St.info : _St.ok,
      ));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Before sleep'), actions: [
        IconButton(
          tooltip: 'Checklist settings',
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NightSettingsScreen())),
          icon: const Icon(Icons.tune),
        ),
      ]),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final items = _items();
          final fixes = items.where((i) => i.st == _St.fix).length;
          final checks = items.where((i) => i.st != _St.info).length;
          final oks = items.where((i) => i.st == _St.ok).length;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Text('Checked at ${fmtClock(_checked, app.settings.flag('time24'))}', style: const TextStyle(color: kMuted)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: fixes > 0 ? const Color(0xFF2A1F0E) : const Color(0xFF102833),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: fixes > 0 ? const Color(0xFF5C4318) : const Color(0xFF1F5770)),
              ),
              child: Row(children: [
                Text('$oks/$checks', style: kMono.copyWith(fontSize: 26, fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(fixes > 0
                      ? '$fixes ${fixes == 1 ? 'thing needs' : 'things need'} fixing before you sleep.'
                      : 'All set. Good night.'),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            Section(children: [
              for (var i = 0; i < items.length; i++)
                RowBox(
                  last: i == items.length - 1,
                  child: Row(children: [
                    Icon(
                      items[i].st == _St.ok
                          ? Icons.check_circle_outline
                          : (items[i].st == _St.fix ? Icons.error_outline : Icons.info_outline),
                      color: items[i].st == _St.ok ? kAccent : (items[i].st == _St.fix ? kAmber : kMuted),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(items[i].title, style: const TextStyle(fontWeight: FontWeight.w500)),
                        Text(items[i].detail, style: const TextStyle(color: kMuted, fontSize: 13)),
                      ]),
                    ),
                    if (items[i].title == 'Sound is on and loud' && !_soundConfirmed)
                      TextButton(onPressed: () => setState(() => _soundConfirmed = true), child: const Text('Done')),
                  ]),
                ),
            ]),
            OutlinedButton(onPressed: _check, child: const Text('Check again')),
            const SizedBox(height: 10),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  app.openNight();
                },
                child: const Text('Start night view', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Phones do not let apps read the ringer switch, so the sound check is one you confirm yourself.',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
          ]);
        },
      ),
    );
  }
}
