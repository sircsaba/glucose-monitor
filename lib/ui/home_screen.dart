import 'package:flutter/material.dart';

import '../logic/glucose.dart';
import '../state/app_state.dart';
import 'bg_chart.dart';
import 'common.dart';
import 'quick_alarms_screen.dart';
import 'reports_screen.dart';
import 'settings/menu_screen.dart';
import 'treat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: const [LiveScreen(), TreatScreen(), ReportsScreen(), QuickAlarmsScreen()],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Live'),
          NavigationDestination(icon: Icon(Icons.add_circle_outline), label: 'Treat'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Reports'),
          NavigationDestination(icon: Icon(Icons.notifications_none), label: 'Alarms'),
        ],
      ),
    );
  }
}

class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});
  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  int? _hours;

  Widget _tile(String label, String value, {String? sub, Color? subColor}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value, style: kMono.copyWith(fontSize: 18, fontWeight: FontWeight.w600)),
          if (sub != null) Text(sub, style: TextStyle(color: subColor ?? kMuted, fontSize: 11)),
        ]),
      ),
    );
  }

  Widget _small(String label, String value) => Expanded(
        child: Column(children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value, style: kMono.copyWith(fontSize: 13)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final s = app.settings;
        final mmol = s.mmol;
        final l = app.latest;
        final age = app.age;
        final stale = app.isStale;
        final color = l == null ? kMuted : (stale ? kMuted : app.colorFor(l.mg));
        final d = app.device;
        final now = DateTime.now();
        final hours = _hours ?? s.integer('graphHours');
        final loopAge = d?.loopTime == null ? null : now.difference(d!.loopTime!);
        final bolus = app.lastBolus;
        final carbs = app.lastCarbs;
        final delta = app.delta5;

        return RefreshIndicator(
          onRefresh: () => app.refresh(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Row(children: [
                Expanded(
                  child: Text(
                    age == null ? 'No readings yet' : fmtAgo(age),
                    style: TextStyle(color: stale ? kAmber : kMuted, fontSize: 13),
                  ),
                ),
                if (loopAge != null) ...[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: loopAge.inMinutes < s.integer('loopMin') ? kAccent : kAmber,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('Loop ${fmtAge(loopAge)}', style: const TextStyle(color: kMuted, fontSize: 13)),
                ],
                IconButton(
                  tooltip: 'Night view',
                  onPressed: app.openNight,
                  icon: const Icon(Icons.bedtime_outlined, color: kMuted),
                ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MenuScreen())),
                  icon: const Icon(Icons.settings_outlined, color: kMuted),
                ),
              ]),
              if (app.error != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFF2A1F0E), borderRadius: BorderRadius.circular(10)),
                  child: Text(app.error!, style: const TextStyle(color: kAmber, fontSize: 13)),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(
                    l == null ? '---' : fmtBg(l.mg, mmol),
                    style: kMono.copyWith(
                      fontSize: 84,
                      height: 1,
                      fontWeight: FontWeight.w600,
                      color: color,
                      decoration: stale && l != null ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (l != null) ArrowIcon(direction: l.direction, size: 40, color: color),
                    Text(delta == null ? '' : fmtDelta(delta, mmol), style: kMono.copyWith(fontSize: 17)),
                    Text(unitLabel(mmol), style: const TextStyle(color: kMuted, fontSize: 12)),
                  ]),
                ]),
              ),
              Row(children: [
                _tile('IOB', d?.iob == null ? '–' : '${d!.iob!.toStringAsFixed(2)} U'),
                const SizedBox(width: 8),
                _tile('COB', d?.cob == null ? '–' : '${d!.cob!.round()} g'),
                const SizedBox(width: 8),
                _tile(
                  'Basal',
                  d?.basal == null ? '–' : d!.basal!.toStringAsFixed(2),
                  sub: (d?.basalMinLeft ?? 0) > 0 ? 'Temp · ${d!.basalMinLeft!.round()} min' : null,
                  subColor: kAmber,
                ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: Text(
                    bolus == null ? 'No bolus in 24 h' : 'Bolus ${bolus.insulin!.toStringAsFixed(1)} U · ${fmtAge(now.difference(bolus.t))} ago',
                    style: const TextStyle(fontSize: 13, color: Color(0xFFC4CCD6)),
                  ),
                ),
                Text(
                  carbs == null ? '' : 'Carbs ${carbs.carbs!.round()} g · ${fmtAge(now.difference(carbs.t))} ago',
                  style: const TextStyle(fontSize: 13, color: Color(0xFFC4CCD6)),
                ),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
                decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
                child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    for (final h in [3, 6, 12, 24])
                      ChoiceChip(
                        label: Text('${h}h'),
                        selected: hours == h,
                        onSelected: (_) => setState(() => _hours = h),
                      ),
                  ]),
                  const SizedBox(height: 6),
                  BgChart(hours: hours),
                ]),
              ),
              const SizedBox(height: 14),
              Row(children: [
                _small('Reservoir', d?.reservoir == null ? '–' : '${d!.reservoir!.round()} U'),
                _small('Battery', d?.pumpBattery == null ? '–' : '${d!.pumpBattery}%'),
                _small('Sensor', app.sensorStart == null ? '–' : fmtAge(now.difference(app.sensorStart!))),
                _small('Cannula', app.siteChange == null ? '–' : fmtAge(now.difference(app.siteChange!))),
              ]),
            ],
          ),
        );
      },
    );
  }
}
