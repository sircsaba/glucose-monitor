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
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 2),
          // Shrinks instead of wrapping on small phones (iPhone SE).
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, maxLines: 1, style: kMono.copyWith(fontSize: 18, fontWeight: FontWeight.w600)),
          ),
          if (sub != null)
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(sub, maxLines: 1, style: TextStyle(color: subColor ?? kMuted, fontSize: 11)),
            ),
        ]),
      ),
    );
  }

  Widget _small(String label, String value, {String? hint}) => Expanded(
        child: Column(children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 2),
          FittedBox(fit: BoxFit.scaleDown, child: Text(value, maxLines: 1, style: kMono.copyWith(fontSize: 13))),
          if (hint != null) Text(hint, style: const TextStyle(color: kMuted, fontSize: 10)),
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
        final buttons = app.graphButtons;
        final hours = _hours != null && buttons.contains(_hours) ? _hours! : s.integer('graphHours');
        final loopAge = d?.loopTime == null ? null : now.difference(d!.loopTime!);
        final bolus = app.lastBolus;
        final carbs = app.lastCarbs;
        final delta = app.delta5;

        String reservoir() {
          if (d?.reservoirText != null) return d!.reservoirText!;
          if (d?.reservoir != null) return '${d!.reservoir!.round()}U';
          return '–';
        }

        String battery() {
          if (d?.pumpBattery != null) return '${d!.pumpBattery}%';
          if (d?.pumpVolts != null) return '${d!.pumpVolts!.toStringAsFixed(2)}V';
          return '–';
        }

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
                if (loopAge != null) LoopBadge(age: loopAge, late: loopAge.inMinutes >= s.integer('loopMin')),
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
                _tile('IOB', d?.iob == null ? '–' : '${d!.iob!.toStringAsFixed(2)}U'),
                const SizedBox(width: 8),
                _tile('COB', d?.cob == null ? '–' : '${d!.cob!.round()}g'),
                const SizedBox(width: 8),
                _tile(
                  'Basal',
                  d?.basal == null ? '–' : '${d!.basal!.toStringAsFixed(2)}U/h',
                  sub: (d?.basalMinLeft ?? 0) > 0 ? 'Temp · ${d!.basalMinLeft!.round()} min' : null,
                  subColor: kAmber,
                ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: Text(
                    bolus == null ? 'No bolus in 24 h' : 'Bolus ${bolus.insulin!.toStringAsFixed(1)}U · ${fmtAge(now.difference(bolus.t))} ago',
                    style: const TextStyle(fontSize: 13, color: Color(0xFFC4CCD6)),
                  ),
                ),
                Text(
                  carbs == null ? '' : 'Carbs ${carbs.carbs!.round()}g · ${fmtAge(now.difference(carbs.t))} ago',
                  style: const TextStyle(fontSize: 13, color: Color(0xFFC4CCD6)),
                ),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
                decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
                child: Column(children: [
                  Row(children: [
                    for (final h in buttons)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: _RangeButton(
                            label: '${h}h',
                            selected: hours == h,
                            onTap: () => setState(() => _hours = h),
                          ),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 6),
                  BgChart(hours: hours),
                ]),
              ),
              const SizedBox(height: 14),
              Row(children: [
                _small('Reservoir', reservoir()),
                _small('Pump battery', battery()),
                _small('Sensor', app.sensorStart == null ? '–' : fmtAge(now.difference(app.sensorStart!))),
                _small('Cannula', app.siteChange == null ? '–' : fmtAge(now.difference(app.siteChange!))),
              ]),
              if (d?.phoneBattery != null) ...[
                const SizedBox(height: 8),
                Center(
                  child: Text('Looping phone battery ${d!.phoneBattery}%', style: const TextStyle(color: kMuted, fontSize: 12)),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _RangeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _RangeButton({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? const Color(0xFF12303D) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: selected ? kAccent : kBorder),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox(
            height: 38,
            child: Center(
              child: Text(label, style: TextStyle(color: selected ? kText : kMuted, fontSize: 14, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Loop 3 min" above the glucose value. When the loop is late it turns
/// bright amber and flashes.
class LoopBadge extends StatefulWidget {
  final Duration age;
  final bool late;
  const LoopBadge({super.key, required this.age, required this.late});
  @override
  State<LoopBadge> createState() => _LoopBadgeState();
}

class _LoopBadgeState extends State<LoopBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant LoopBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.late && !_blink.isAnimating) {
      _blink.repeat(reverse: true);
    } else if (!widget.late && _blink.isAnimating) {
      _blink.stop();
      _blink.value = 1;
    }
    if (!widget.late) _blink.value = 1;
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const bright = Color(0xFFFFB020);
    final text = Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: widget.late ? 10 : 8,
        height: widget.late ? 10 : 8,
        decoration: BoxDecoration(color: widget.late ? bright : kAccent, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(
        'Loop ${fmtAge(widget.age)}',
        style: TextStyle(
          color: widget.late ? bright : kMuted,
          fontSize: widget.late ? 15 : 13,
          fontWeight: widget.late ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
    ]);
    if (!widget.late) return text;
    return FadeTransition(opacity: Tween<double>(begin: 0.25, end: 1.0).animate(_blink), child: text);
  }
}
