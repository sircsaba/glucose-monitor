import 'dart:async';

import 'package:flutter/material.dart';

import '../logic/glucose.dart';
import '../state/app_state.dart';
import '../state/settings.dart';
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

  static const _tabs = [
    (Icons.show_chart, 'Live'),
    (Icons.add_circle_outline, 'Treat'),
    (Icons.bar_chart, 'Reports'),
    (Icons.notifications_none, 'Alarms'),
  ];

  /// Thin bottom bar: on a computer by default, or as set.
  bool _compactNav(BuildContext context) {
    final mode = app.settings.integer('navCompact');
    return mode == 1 || (mode == 0 && DayView.isWide(context));
  }

  /// About 40 px high instead of 80: icon and name side by side.
  Widget _thinBar() {
    return Material(
      color: const Color(0xFF11161D),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 40,
          child: Row(children: [
            for (var i = 0; i < _tabs.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _tab = i),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                    decoration: BoxDecoration(
                      color: _tab == i ? const Color(0xFF12303D) : Colors.transparent,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(_tabs[i].$1, size: 18, color: _tab == i ? kText : kMuted),
                      const SizedBox(width: 6),
                      Text(_tabs[i].$2, style: TextStyle(fontSize: 13, color: _tab == i ? kText : kMuted)),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (c, _) => _scaffold(c));

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: const [LiveScreen(), TreatScreen(), ReportsScreen(), QuickAlarmsScreen()],
        ),
      ),
      bottomNavigationBar: _compactNav(context) ? _thinBar() : NavigationBar(
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

class LiveScreen extends StatelessWidget {
  const LiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        const pad = EdgeInsets.fromLTRB(12, 2, 12, 12);
        if (!DayView.fitsGraph(context)) {
          return RefreshIndicator(
            onRefresh: () => app.refresh(),
            child: ListView(padding: pad, children: const [DayView()]),
          );
        }
        // The graph takes the room that is left, so everything fits the screen.
        // On a screen too small for that, the page scrolls instead.
        return RefreshIndicator(
          onRefresh: () => app.refresh(),
          child: const CustomScrollView(slivers: [
            SliverPadding(
              padding: pad,
              sliver: SliverFillRemaining(hasScrollBody: false, child: DayView(fill: true)),
            ),
          ]),
        );
      },
    );
  }
}

/// The main screen, laid out from Settings › Day view layout: each element has
/// its own size, colour, alignment, width share and line. Used by the Live tab
/// and by the layout editor preview ([preview], [highlight], [onSelect]).
class DayView extends StatefulWidget {
  final bool preview;
  final String? highlight;
  final ValueChanged<String>? onSelect;
  final bool? wide; // preview: which default to show
  final bool fill; // the graph takes the height that is left
  const DayView({super.key, this.preview = false, this.highlight, this.onSelect, this.wide, this.fill = false});

  /// Graph height: fit the screen (on a computer by default), or the fixed size.
  static bool fitsGraph(BuildContext context) {
    final mode = app.settings.integer('graphFit');
    return mode == 1 || (mode == 0 && isWide(context));
  }

  /// A computer screen or a wide window: picks the compact, larger default.
  static bool isWide(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return size.width >= 900 && size.width > size.height;
  }

  @override
  State<DayView> createState() => _DayViewState();
}

class _DayViewState extends State<DayView> {
  int? _hours;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Keeps the clock and "min ago" current between data refreshes.
    _tick = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static Alignment _align(String a) => a == 'left' ? Alignment.centerLeft : (a == 'right' ? Alignment.centerRight : Alignment.center);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (c, _) => _content(c, widget.wide ?? DayView.isWide(c)),
      );

  Widget _content(BuildContext context, bool wide) {
    final s = app.settings;
    final mmol = s.mmol;
    final l = app.latest;
    final age = app.age;
    final stale = app.isStale;
    final zc = l == null || stale ? kMuted : app.colorFor(l.mg);
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

    String ageOf(DateTime? t) => t == null ? '–' : fmtAge(now.difference(t));

    Widget content(LineCfg c) {
      final col = c.zoneColor ? zc : Color(c.color);
      final size = c.size;
      final weight = c.bold ? FontWeight.w600 : FontWeight.w400;
      final align = _align(c.align);

      // "Label value" on one line, or the label above the value (stack).
      Widget pair(String label, String value, {Color? labelColor, String? sub}) {
        final valueStyle = kMono.copyWith(color: col, fontSize: size, fontWeight: weight);
        if (c.stack) {
          final cross = c.align == 'left'
              ? CrossAxisAlignment.start
              : (c.align == 'right' ? CrossAxisAlignment.end : CrossAxisAlignment.center);
          return Column(crossAxisAlignment: cross, mainAxisSize: MainAxisSize.min, children: [
            Text(label, maxLines: 1, style: TextStyle(color: labelColor ?? kMuted, fontSize: size < 18 ? 12 : size * 0.66)),
            const SizedBox(height: 2),
            FittedBox(fit: BoxFit.scaleDown, alignment: align, child: Text(value, maxLines: 1, style: valueStyle)),
            if (sub != null)
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: align,
                child: Text(sub, maxLines: 1, style: TextStyle(color: kAmber, fontSize: size < 18 ? 11 : size * 0.6)),
              ),
          ]);
        }
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: align,
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '$label ', style: TextStyle(color: labelColor ?? kMuted, fontSize: size * 0.85)),
              TextSpan(text: value, style: valueStyle),
            ]),
            maxLines: 1,
          ),
        );
      }

      Widget text(String t, {Color? color}) => FittedBox(
            fit: BoxFit.scaleDown,
            alignment: align,
            child: Text(t, maxLines: 1, style: kMono.copyWith(color: color ?? col, fontSize: size, fontWeight: weight)),
          );

      switch (c.id) {
        case 'ago':
          // Like the loop status: a dot, flashing bright when the reading is old.
          if (age == null) return text('No readings yet', color: kAmber);
          return Align(
            alignment: align,
            child: LoopBadge(age: age, late: stale, size: size, text: fmtAgo(age), color: col),
          );
        case 'loop':
          if (loopAge == null) return const SizedBox.shrink();
          return Align(alignment: align, child: LoopBadge(age: loopAge, late: loopAge.inMinutes >= s.integer('loopMin'), size: size));
        case 'clock':
          return text(fmtClock(now, s.flag('time24')));
        case 'bg':
          final valueStyle = kMono.copyWith(
            fontSize: size,
            height: 1,
            fontWeight: weight,
            color: col,
            letterSpacing: -size * 0.02,
            decoration: stale && l != null ? TextDecoration.lineThrough : null,
          );
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: align,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(l == null ? '---' : fmtBg(l.mg, mmol), style: valueStyle),
              if (l != null && (s.flag('dayArrow') || s.flag('dayBgDelta'))) ...[
                SizedBox(width: size * 0.095),
                Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  if (s.flag('dayArrow'))
                    ArrowIcon(direction: l.direction, size: size * 0.48, color: col, length: s.integer('arrowLen') / 100.0),
                  if (s.flag('dayBgDelta')) ...[
                    Text(delta == null ? '' : fmtDelta(delta, mmol), style: kMono.copyWith(fontSize: size * 0.2, color: kText)),
                    Text(unitLabel(mmol), style: TextStyle(color: kMuted, fontSize: size * 0.14)),
                  ],
                ]),
              ],
            ]),
          );
        case 'delta':
          return text(delta == null ? '' : '${fmtDelta(delta, mmol)} ${unitLabel(mmol)}');
        case 'iob':
          return pair('IOB', d?.iob == null ? '–' : '${d!.iob!.toStringAsFixed(2)}U');
        case 'cob':
          return pair('COB', d?.cob == null ? '–' : '${d!.cob!.round()}g');
        case 'basal':
          final temp = (d?.basalMinLeft ?? 0) > 0;
          final rate = d?.basal == null ? '–' : '${d!.basal!.toStringAsFixed(2)}U/h';
          if (c.stack) return pair('Basal', rate, sub: temp ? 'Temp · ${d!.basalMinLeft!.round()} min' : null);
          return pair(temp ? 'Temp' : 'Basal', rate, labelColor: temp ? kAmber : null);
        case 'reservoir':
          return pair(c.stack ? 'Reservoir' : 'Res', reservoir());
        case 'battery':
          return pair(c.stack ? 'Pump battery' : 'Batt', battery());
        case 'bolus':
          return text(bolus == null ? 'No bolus in 24 h' : 'Bolus ${bolus.insulin!.toStringAsFixed(1)}U · ${fmtAge(now.difference(bolus.t))} ago');
        case 'carbs':
          return text(carbs == null ? '' : 'Carbs ${carbs.carbs!.round()}g · ${fmtAge(now.difference(carbs.t))} ago');
        case 'sensor':
          return pair('Sensor', ageOf(app.sensorStart));
        case 'cannula':
          return pair('Cannula', ageOf(app.siteChange));
        case 'phone':
          if (d?.phoneBattery == null && !c.box) return const SizedBox.shrink();
          final pct = d?.phoneBattery == null ? '–' : '${d!.phoneBattery}%';
          if (c.box) return pair('Phone', pct);
          return pair(c.stack ? 'Looping phone' : 'Looping phone battery', pct);
        case 'graph':
          return Container(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
            child: Column(children: [
              Row(children: [
                for (final h in buttons)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: _RangeButton(label: '${h}h', selected: hours == h, short: wide, onTap: () => setState(() => _hours = h)),
                    ),
                  ),
              ]),
              const SizedBox(height: 6),
              if (widget.fill) Expanded(child: BgChart(hours: hours, height: null)) else BgChart(hours: hours, height: size),
            ]),
          );
      }
      return const SizedBox.shrink();
    }

    Widget cell(LineCfg c) {
      Widget w = content(c);
      if (c.box && c.id != 'graph') {
        w = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
          child: Align(alignment: _align(c.align), child: w),
        );
      } else if (c.id != 'graph') {
        w = Align(alignment: _align(c.align), child: w);
      }
      if (widget.highlight == c.id) {
        w = DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(border: Border.all(color: kAccent, width: 2), borderRadius: BorderRadius.circular(6)),
          child: w,
        );
      }
      if (widget.onSelect != null) {
        w = GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => widget.onSelect!(c.id), child: w);
      }
      return w;
    }

    // Elements marked "same line as the one before" share a line. Lines are
    // worked out with hidden elements too, so hiding one doesn't move the others.
    final groups = <List<LineCfg>>[];
    for (final c in s.dayFor(wide)) {
      final canJoin = (c.join || c.under) && groups.isNotEmpty && c.id != 'graph' && groups.last.first.id != 'graph';
      if (canJoin) {
        groups.last.add(c);
      } else {
        groups.add([c]);
      }
    }
    for (final g in groups) {
      g.removeWhere((c) => !c.show);
    }
    groups.removeWhere((g) => g.isEmpty);

    final icons = Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: 'Night view',
        visualDensity: VisualDensity.compact,
        onPressed: widget.preview ? null : app.openNight,
        icon: const Icon(Icons.bedtime_outlined, color: kMuted),
      ),
      IconButton(
        tooltip: 'Settings',
        visualDensity: VisualDensity.compact,
        onPressed: widget.preview ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MenuScreen())),
        icon: const Icon(Icons.settings_outlined, color: kMuted),
      ),
    ]);

    Widget line(List<LineCfg> g, {bool first = false}) {
      // Elements marked "under the element before" share its spot, one above the other.
      final spots = <List<LineCfg>>[];
      for (final c in g) {
        if (c.under && spots.isNotEmpty) {
          spots.last.add(c);
        } else {
          spots.add([c]);
        }
      }
      final children = <Widget>[];
      for (var i = 0; i < spots.length; i++) {
        if (i > 0) children.add(SizedBox(width: wide ? 10 : 6));
        final sp = spots[i];
        children.add(Expanded(
          flex: sp.first.flex,
          child: sp.length == 1
              ? cell(sp.first)
              : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var k = 0; k < sp.length; k++)
                    Padding(padding: EdgeInsets.only(top: k == 0 ? 0 : sp[k].space), child: cell(sp[k])),
                ]),
        ));
      }
      if (first) children.add(icons);
      return Padding(
        padding: EdgeInsets.only(top: g.first.space),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: children),
      );
    }

    final errorBox = app.error == null || widget.preview
        ? null
        : Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF2A1F0E), borderRadius: BorderRadius.circular(10)),
            child: Text(app.error!, style: const TextStyle(color: kAmber, fontSize: 13)),
          );

    final rows = <Widget>[];
    var filled = false;
    for (var gi = 0; gi < groups.length; gi++) {
      final g = groups[gi];
      if (widget.fill && !filled && g.first.id == 'graph') {
        // The graph stretches into the free height (at least 180 px).
        filled = true;
        rows.add(Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 180),
            child: Padding(padding: EdgeInsets.only(top: g.first.space), child: cell(g.first)),
          ),
        ));
        continue;
      }
      rows.add(line(g, first: gi == 0));
      if (gi == 0 && errorBox != null) rows.add(errorBox);
    }
    if (groups.isEmpty) rows.add(Align(alignment: Alignment.centerRight, child: icons));
    return Column(
      mainAxisSize: filled ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

class _RangeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool short;
  const _RangeButton({required this.label, required this.selected, required this.onTap, this.short = false});

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
            height: short ? 30 : 38,
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
  final double size;
  final String? text; // instead of "Loop 3 min"
  final Color color; // text colour while on time
  const LoopBadge({super.key, required this.age, required this.late, this.size = 13, this.text, this.color = kMuted});
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
        width: widget.size * (widget.late ? 0.75 : 0.6),
        height: widget.size * (widget.late ? 0.75 : 0.6),
        decoration: BoxDecoration(color: widget.late ? bright : kAccent, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(
        widget.text ?? 'Loop ${fmtAge(widget.age)}',
        style: TextStyle(
          color: widget.late ? bright : widget.color,
          fontSize: widget.size * (widget.late ? 1.15 : 1.0),
          fontWeight: widget.late ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
    ]);
    if (!widget.late) return text;
    return FadeTransition(opacity: Tween<double>(begin: 0.25, end: 1.0).animate(_blink), child: text);
  }
}
