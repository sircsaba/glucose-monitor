import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../logic/glucose.dart';
import '../state/app_state.dart';
import '../state/settings.dart';
import 'bg_chart.dart';
import 'common.dart';

/// Fake values used by the layout editor preview.
class PreviewValues {
  final double mg;
  final String direction;
  final double deltaMg;
  final Color color;
  const PreviewValues(this.mg, this.direction, this.deltaMg, this.color);
}

/// The night view lines, laid out from the settings. Used by the night
/// screen and by the layout editor preview (with [scale] and [preview]).
class NightView extends StatelessWidget {
  final double scale;
  final PreviewValues? preview;
  final String? highlight;
  const NightView({super.key, this.scale = 1.0, this.preview, this.highlight});

  Alignment _align(String a) => a == 'left' ? Alignment.centerLeft : (a == 'right' ? Alignment.centerRight : Alignment.center);
  TextAlign _talign(String a) => a == 'left' ? TextAlign.left : (a == 'right' ? TextAlign.right : TextAlign.center);
  MainAxisAlignment _main(String a) =>
      a == 'left' ? MainAxisAlignment.start : (a == 'right' ? MainAxisAlignment.end : MainAxisAlignment.center);

  // The night screen holds this widget as a const, so it must listen for new
  // readings itself; otherwise Flutter keeps showing the first values.
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (c, _) => _content(c));

  Widget _content(BuildContext context) {
    final s = app.settings;
    final mmol = s.mmol;
    final now = DateTime.now();
    final l = app.latest;
    final stale = preview == null && app.isStale;
    final mg = preview?.mg ?? l?.mg;
    final dir = preview?.direction ?? l?.direction ?? '';
    final zc = preview?.color ?? (mg == null ? kMuted : app.colorFor(mg));
    final delta = preview?.deltaMg ?? app.delta5;
    final age = preview != null ? const Duration(minutes: 3) : app.age;
    final d = app.device;
    final bolus = app.lastBolus;
    final carbs = app.lastCarbs;

    Widget lineWidget(LineCfg c) {
      final color = c.zoneColor ? zc : Color(c.color);
      final size = c.size * scale;
      final weight = c.bold ? FontWeight.w600 : FontWeight.w400;
      final mono = c.id == 'bg' || c.id == 'clock' || c.id == 'delta';
      TextStyle st(Color col) => (mono ? kMono : const TextStyle()).copyWith(
            fontSize: size,
            color: col,
            fontWeight: weight,
            height: 1.05,
            letterSpacing: c.id == 'bg' ? -size * 0.03 : null,
          );
      Widget child;
      switch (c.id) {
        case 'clock':
          child = Text(fmtClock(now, s.flag('time24')), style: st(color), textAlign: _talign(c.align));
          break;
        case 'bg':
          child = Row(mainAxisAlignment: _main(c.align), mainAxisSize: MainAxisSize.max, children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  mg == null ? '---' : fmtBg(mg, mmol),
                  style: st(color).copyWith(decoration: stale ? TextDecoration.lineThrough : null),
                ),
              ),
            ),
            if (s.flag('nightArrow') && mg != null) ArrowIcon(direction: dir, size: size * 0.5, color: color),
          ]);
          break;
        case 'ago':
          child = Text(
            age == null ? 'No data' : fmtAgo(age),
            style: st(stale ? kAmber : color),
            textAlign: _talign(c.align),
          );
          break;
        case 'delta':
          child = Text(
            delta == null ? '' : '${fmtDelta(delta, mmol)} ${unitLabel(mmol)} (5 min avg)',
            style: st(color),
            textAlign: _talign(c.align),
          );
          break;
        case 'since':
          final b = preview != null
              ? 'Bolus 4.5 U · 2h 31m ago'
              : (bolus == null ? 'No bolus in 24 h' : 'Bolus ${fmtU(bolus.insulin!)} U · ${fmtAgo(now.difference(bolus.t))}');
          final cb = preview != null
              ? 'Carbs 45 g · 2h 31m ago'
              : (carbs == null ? '' : 'Carbs ${carbs.carbs!.round()} g · ${fmtAgo(now.difference(carbs.t))}');
          child = Text(cb.isEmpty ? b : '$b\n$cb', style: st(color), textAlign: _talign(c.align));
          break;
        case 'iob':
          child = Text(
            'IOB ${d?.iob?.toStringAsFixed(2) ?? '–'} U · COB ${d?.cob?.round() ?? '–'} g',
            style: st(color),
            textAlign: _talign(c.align),
          );
          break;
        case 'graph':
          child = SparkLine(height: size, color: color);
          break;
        default:
          child = const SizedBox.shrink();
      }
      final boxed = Align(alignment: _align(c.align), child: child);
      return Padding(
        padding: EdgeInsets.only(top: c.space * scale),
        child: highlight == c.id
            ? DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: kAccent.withValues(alpha: 0.7)), borderRadius: BorderRadius.circular(4)),
                child: boxed,
              )
            : boxed,
      );
    }

    final shown = s.lines.where((c) => c.show).toList();
    final pos = s.integer('nightBlockPos');
    final mainAxis = pos == 0 ? MainAxisAlignment.start : (pos == 2 ? MainAxisAlignment.end : MainAxisAlignment.center);

    return LayoutBuilder(builder: (context, box) {
      final landscape = preview == null && box.maxWidth > box.maxHeight * 1.2;
      if (landscape) {
        final bgLine = shown.where((c) => c.id == 'bg').toList();
        final rest = shown.where((c) => c.id != 'bg' && c.id != 'graph').toList();
        return Row(children: [
          Expanded(flex: 3, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: bgLine.map(lineWidget).toList())),
          const SizedBox(width: 24),
          Expanded(
            flex: 2,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: rest.map(lineWidget).toList()),
          ),
        ]);
      }
      return Column(
        mainAxisAlignment: mainAxis,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: shown.map(lineWidget).toList(),
      );
    });
  }
}

class NightScreen extends StatefulWidget {
  const NightScreen({super.key});
  @override
  State<NightScreen> createState() => _NightScreenState();
}

class _NightScreenState extends State<NightScreen> {
  bool _controls = false;
  Timer? _hide;
  Timer? _shift;
  Offset _offset = Offset.zero;
  final _rnd = math.Random();

  @override
  void initState() {
    super.initState();
    final s = app.settings;
    if (s.flag('nightKeepAwake')) WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    final o = s.integer('nightOrientation');
    if (o == 1) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    } else if (o == 2) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
    _shift = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted || !app.settings.flag('nightBurnIn')) return;
      setState(() => _offset = Offset(_rnd.nextDouble() * 16 - 8, _rnd.nextDouble() * 16 - 8));
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    _shift?.cancel();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _toggle() {
    setState(() => _controls = !_controls);
    _hide?.cancel();
    if (_controls) {
      _hide = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _controls = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) {
            final op = (app.settings.integer('nightBrightness') / 100.0).clamp(0.05, 1.0);
            return Stack(children: [
              Positioned.fill(
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                    child: Transform.translate(
                      offset: _offset,
                      child: Opacity(opacity: op, child: const NightView()),
                    ),
                  ),
                ),
              ),
              if (_controls)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 24,
                  child: SafeArea(
                    child: Opacity(
                      opacity: 0.7,
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        OutlinedButton(
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _NightQuick())),
                          child: const Text('Brightness'),
                        ),
                        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                      ]),
                    ),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Quick brightness change without leaving the night view.
class _NightQuick extends StatelessWidget {
  const _NightQuick();
  @override
  Widget build(BuildContext context) {
    return SettingsPage(title: 'Night view', builder: (context) => [
      Section(children: [
        setInt('Brightness', 'nightBrightness', step: 5, min: 5, max: 100, unit: '%'),
        setSwitch('Trend arrow', 'nightArrow'),
        setSwitch('Move text slowly', 'nightBurnIn', hint: 'Prevents screen burn-in'),
      ]),
    ]);
  }
}
