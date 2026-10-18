import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/nightscout.dart';
import '../logic/glucose.dart';
import '../logic/insulin.dart';
import '../logic/profile.dart';
import '../state/app_state.dart';
import '../state/settings.dart';
import 'common.dart';

/// Glucose graph: dots by zone, prediction, treatments and temp basal, dotted
/// grid, and a small label when the mouse is over a reading or a treatment
/// (on a phone: tap, or touch and hold and slide).
class BgChart extends StatefulWidget {
  final int hours;
  final double? height; // null: take the height it is given (graph fits the screen)
  const BgChart({super.key, required this.hours, this.height = 260});

  @override
  State<BgChart> createState() => _BgChartState();
}

/// Minutes between vertical grid lines for each of the 5 graph buttons.
List<int> gridMinutesList() {
  final raw = app.settings.raw('gridMinutes');
  final list = raw is List ? raw.whereType<num>().map((e) => e.toInt()).toList() : <int>[];
  const def = [15, 15, 15, 30, 60];
  return [for (var i = 0; i < 5; i++) i < list.length && list[i] > 0 ? list[i] : def[i]];
}

class _BgChartState extends State<BgChart> {
  Offset? _pos;
  Timer? _hide;

  // Going back in time: drag the graph sideways (or the arrows). Older data
  // than the app keeps (about a day) is loaded from the site as needed.
  Duration _back = Duration.zero;
  double _width = 1;
  List<Entry> _oldEntries = [];
  List<Treatment> _oldTreats = [];
  DateTime? _oldFrom; // older data loaded back to here
  bool _loadingOld = false;
  static const _maxBack = Duration(days: 90);

  DateTime get _liveEarliest {
    final e = app.entries;
    return e.isEmpty ? DateTime.now().subtract(const Duration(hours: 24)) : e.first.t;
  }

  Future<void> _ensureOld(DateTime viewStart) async {
    final have = _oldFrom ?? _liveEarliest;
    if (_loadingOld || !viewStart.isBefore(have.add(const Duration(minutes: 10)))) return;
    _loadingOld = true;
    if (mounted) setState(() {});
    final from = viewStart.subtract(Duration(hours: math.max(6, widget.hours * 2)));
    try {
      final c = app.client;
      final es = await c.entriesBetween(from, have);
      final ts = await c.treatmentsBetween(from.subtract(const Duration(hours: 12)), have);
      final em = <int, Entry>{for (final e in _oldEntries) e.t.millisecondsSinceEpoch: e};
      for (final e in es) {
        em[e.t.millisecondsSinceEpoch] = e;
      }
      final seen = {for (final t in _oldTreats) '${t.t.millisecondsSinceEpoch}|${t.type}'};
      final tl = [..._oldTreats];
      for (final t in ts) {
        if (seen.add('${t.t.millisecondsSinceEpoch}|${t.type}')) tl.add(t);
      }
      _oldEntries = em.values.toList()..sort((a, b) => a.t.compareTo(b.t));
      _oldTreats = tl;
      _oldFrom = from;
    } catch (_) {}
    _loadingOld = false;
    if (mounted) setState(() {});
  }

  void _shift(Duration d) {
    var b = _back + d;
    if (b < Duration.zero) b = Duration.zero;
    if (b > _maxBack) b = _maxBack;
    setState(() => _back = b);
    _ensureOld(DateTime.now().subtract(b).subtract(Duration(hours: widget.hours)));
  }

  void _drag(double dx) {
    final span = widget.hours * 3600.0;
    _shift(Duration(seconds: (dx / math.max(1, _width) * span).round()));
  }

  void _show(Offset? p, {bool autoHide = false}) {
    _hide?.cancel();
    setState(() => _pos = p);
    if (autoHide && p != null) {
      _hide = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _pos = null);
      });
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    final buttons = app.graphButtons;
    final bi = buttons.indexOf(widget.hours);
    final gridMin = bi >= 0 && bi < 5 ? gridMinutesList()[bi] : (widget.hours <= 3 ? 15 : (widget.hours <= 6 ? 30 : 60));
    final tipBg = s.integer('tipBg');
    final tipTreat = s.integer('tipTreat');
    final live = _back == Duration.zero;
    final viewNow = DateTime.now().subtract(_back);
    var entries = app.entries;
    var treatments = app.treatments;
    if (!live) {
      final liveFrom = _liveEarliest;
      entries = [..._oldEntries.where((e) => e.t.isBefore(liveFrom)), ...app.entries].where((e) => !e.t.isAfter(viewNow)).toList();
      final tf = app.treatments.isEmpty ? DateTime.now() : app.treatments.map((t) => t.t).reduce((a, b) => a.isBefore(b) ? a : b);
      treatments = [..._oldTreats.where((t) => t.t.isBefore(tf)), ...app.treatments].where((t) => !t.t.isAfter(viewNow)).toList();
    }
    final plot = SizedBox(
      height: widget.height,
      width: double.infinity,
      child: CustomPaint(
        painter: _BgPainter(
          entries: entries,
          treatments: treatments,
          device: app.device,
          ranges: s.ranges,
          mmol: s.mmol,
          hours: widget.hours,
          showPred: live && s.flag('showPrediction'),
          showBasal: s.flag('showBasal'),
          showTreat: s.flag('showTreatments'),
          h24: s.flag('time24'),
          now: viewNow,
          topMg: s.number('graphTop'),
          dotScale: const [1.0, 1.4, 1.9, 2.5][s.integer('dotSize').clamp(0, 3)],
          treatScale: (s.integer('treatSize') / 100.0).clamp(0.5, 3.0),
          treatOnLine: s.integer('treatPlace') == 1,
          grid: s.flag('gridLines'),
          basalLabels: s.flag('basalLabels'),
          basalBar: Color(s.integer('basalBarColor')),
          basalText: Color(s.integer('basalTextColor')),
          basalSize: s.number('basalTextSize').clamp(7.0, 30.0),
          basalBold: s.flag('basalTextBold'),
          presets: s.flag('presetShow'),
          presetColor: Color(s.integer('presetColor')),
          presetSize: s.number('presetTextSize').clamp(7.0, 30.0),
          presetBold: s.flag('presetBold'),
          gridMin: gridMin,
          hover: _pos,
          tipBg: tipBg,
          tipTreat: tipTreat,
          ttirHi: s.flag('ttirOn') ? s.number('ttirHi') : null,
          ttirColor: Color(s.integer('ttirColor')),
          dotBright: s.integer('dotBright') / 100.0,
          profiles: s.flag('profileShow') ? app.profiles : null,
          basalProfiles: app.profiles,
        ),
      ),
    );
    final tips = tipBg != 0 || tipTreat != 0;
    final chart = LayoutBuilder(builder: (context, c) {
      _width = c.maxWidth;
      return MouseRegion(
        onHover: tips ? (e) => _show(e.localPosition) : null,
        onExit: tips ? (_) => _show(null) : null,
        child: GestureDetector(
          onTapDown: tips ? (d) => _show(d.localPosition, autoHide: true) : null,
          onLongPressStart: tips ? (d) => _show(d.localPosition) : null,
          onLongPressMoveUpdate: tips ? (d) => _show(d.localPosition) : null,
          onLongPressEnd: tips ? (d) => _show(d.localPosition, autoHide: true) : null,
          // Drag right: back in time; drag left: towards now.
          onHorizontalDragUpdate: (d) => _drag(d.delta.dx),
          child: plot,
        ),
      );
    });
    final h24 = s.flag('time24');
    String dayTime(DateTime t) => '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1]} ${fmtClock(t, h24)}';
    final step = Duration(minutes: math.max(15, widget.hours * 30)); // half a screen
    // Fill the space given (graph that fits the screen) or keep its height.
    return Stack(fit: widget.height == null ? StackFit.expand : StackFit.loose, children: [
      chart,
      Positioned(
        right: 4,
        top: 0,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (_loadingOld) const Padding(padding: EdgeInsets.all(6), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
          if (!live)
            Text('${dayTime(viewNow.subtract(Duration(hours: widget.hours)))} – ${dayTime(viewNow)}', style: const TextStyle(color: kMuted, fontSize: 11)),
          _arrow(Icons.keyboard_double_arrow_left, '24 hours earlier', () => _shift(const Duration(hours: 24))),
          _arrow(Icons.chevron_left, 'Earlier', () => _shift(step)),
          if (!live) _arrow(Icons.chevron_right, 'Later', () => _shift(-step)),
          if (!live) _arrow(Icons.keyboard_double_arrow_right, '24 hours later', () => _shift(const Duration(hours: -24))),
          if (!live)
            TextButton(
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 28), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onPressed: () => setState(() => _back = Duration.zero),
              child: const Text('Now'),
            ),
        ]),
      ),
    ]);
  }

  Widget _arrow(IconData icon, String tip, VoidCallback onTap) => IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        iconSize: 20,
        color: kMuted,
        onPressed: onTap,
        icon: Icon(icon),
      );
}

/// Something under the mouse: a treatment marker.
class _Hit {
  final Offset at;
  final String what;
  final DateTime t;
  _Hit(this.at, this.what, this.t);
}

class _BgPainter extends CustomPainter {
  final List<Entry> entries;
  final List<Treatment> treatments;
  final DeviceInfo? device;
  final List<ZoneRange> ranges;
  final bool mmol;
  final int hours;
  final bool showPred;
  final bool showBasal;
  final bool showTreat;
  final bool h24;
  final DateTime now;
  final double topMg; // 0 = auto
  final double dotScale;
  final double treatScale;
  final bool treatOnLine;
  final bool grid;
  final bool basalLabels;
  final Color basalBar;
  final Color basalText;
  final double basalSize;
  final bool basalBold;
  final bool presets;
  final Color presetColor;
  final double presetSize;
  final bool presetBold;
  final int gridMin;
  final Offset? hover;
  final int tipBg; // 0 nothing, 1 value, 2 value and time, 3 time
  final int tipTreat;
  final double? ttirHi; // null = TTIR off
  final Color ttirColor;
  final double dotBright;
  final List<ProfileDoc>? profiles; // null = profile not shown
  final List<ProfileDoc> basalProfiles; // scheduled basal between temp basals

  _BgPainter({
    required this.entries,
    required this.treatments,
    required this.device,
    required this.ranges,
    required this.mmol,
    required this.hours,
    required this.showPred,
    required this.showBasal,
    required this.showTreat,
    required this.h24,
    required this.now,
    required this.topMg,
    required this.dotScale,
    required this.treatScale,
    required this.treatOnLine,
    required this.grid,
    required this.basalLabels,
    required this.basalBar,
    required this.basalText,
    required this.basalSize,
    required this.basalBold,
    required this.presets,
    required this.presetColor,
    required this.presetSize,
    required this.presetBold,
    required this.gridMin,
    required this.hover,
    required this.tipBg,
    required this.tipTreat,
    required this.ttirHi,
    required this.ttirColor,
    required this.dotBright,
    required this.profiles,
    required this.basalProfiles,
  });

  static void _dotted(Canvas c, Offset a, Offset b, Paint p, {double on = 2, double off = 3}) {
    final d = b - a;
    final len = d.distance;
    if (len <= 0) return;
    final u = d / len;
    for (var t = 0.0; t < len; t += on + off) {
      c.drawLine(a + u * t, a + u * math.min(t + on, len), p);
    }
  }

  void _text(Canvas c, String s, Offset at, {Color color = kMuted, double size = 10, bool center = false, bool right = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = at.dx;
    if (center) dx -= tp.width / 2;
    if (right) dx -= tp.width;
    tp.paint(c, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 30.0;
    const right = 6.0;
    final k = treatScale;
    final top = showTreat && !treatOnLine ? 30.0 * k : (showTreat ? 8.0 + 14 * k : 8.0);
    const bottomLabels = 16.0;
    final basalH = showBasal ? (basalLabels ? 30.0 + basalSize * 1.3 : 30.0) : 0.0;
    final plotBottom = size.height - bottomLabels - basalH - 4;
    final w = size.width - left - right;
    final plotH = plotBottom - top;
    if (w <= 0 || plotH <= 0) return;

    final pred = showPred ? (device?.mainPrediction ?? const <double>[]) : const <double>[];
    final predStart = device?.predStart;
    final futureMin = (showPred && pred.isNotEmpty) ? math.min(60, math.max(20, hours * 8)) : 5;
    final tStart = now.subtract(Duration(hours: hours));
    final tEnd = now.add(Duration(minutes: futureMin));
    final span = tEnd.difference(tStart).inSeconds.toDouble();
    double x(DateTime t) => left + t.difference(tStart).inSeconds / span * w;

    final visible = entries.where((e) => e.t.isAfter(tStart) && !e.t.isAfter(tEnd)).toList();
    final rr = activeRange(ranges, now);
    // Top of the graph: fixed from settings, or just above the high line and
    // the highest reading. Rounded up to the next grid line.
    final gridStep = mmol ? 2 * mgPerMmol : 40.0;
    final minMg = mmol ? 2 * mgPerMmol : 40.0;
    var maxMg = topMg > 0 ? topMg : math.max(rr.yelHi, mmol ? 10 * mgPerMmol : 200.0);
    if (topMg <= 0) {
      for (final e in visible) {
        if (e.mg + 5 > maxMg) maxMg = e.mg + 5;
      }
      // Round up to the next grid line (10, 12, 14… mmol/L).
      maxMg = minMg + ((maxMg - minMg) / gridStep - 0.01).ceil() * gridStep;
    }
    double y(double mg) => top + (1 - (mg.clamp(minMg, maxMg) - minMg) / (maxMg - minMg)) * plotH;

    final r = rr;
    // Green band and zone lines, in this range's colours. With TTIR on, the
    // part of the range above the tight range has its own tint.
    final tightTop = ttirHi;
    if (tightTop != null && tightTop > r.yelLo && tightTop < r.yelHi) {
      canvas.drawRect(Rect.fromLTRB(left, y(tightTop), left + w, y(r.yelLo)), Paint()..color = Color(r.cGreen).withValues(alpha: 0.08));
      canvas.drawRect(Rect.fromLTRB(left, y(r.yelHi), left + w, y(tightTop)), Paint()..color = ttirColor.withValues(alpha: 0.13));
      _dotted(canvas, Offset(left, y(tightTop)), Offset(left + w, y(tightTop)), Paint()
        ..color = ttirColor.withValues(alpha: 0.45)
        ..strokeWidth = 1);
    } else {
      canvas.drawRect(Rect.fromLTRB(left, y(r.yelHi), left + w, y(r.yelLo)), Paint()..color = Color(r.cGreen).withValues(alpha: 0.08));
    }
    final line = Paint()..strokeWidth = 1;
    for (final v in [r.yelLo, r.yelHi]) {
      line.color = Color(r.cYel).withValues(alpha: 0.35);
      canvas.drawLine(Offset(left, y(v)), Offset(left + w, y(v)), line);
    }
    for (final v in [r.redLo, r.redHi]) {
      line.color = Color(r.cRed).withValues(alpha: 0.35);
      canvas.drawLine(Offset(left, y(v)), Offset(left + w, y(v)), line);
    }

    // Horizontal grid: 2, 4, 6, 8, 10, 12… mmol/L (40, 80, 120… mg/dL), dotted.
    final gridPaint = Paint()
      ..color = const Color(0xFF3A4350)
      ..strokeWidth = 1;
    for (var k = 0; k < 40; k++) {
      final mg = minMg + k * gridStep;
      if (mg > maxMg + 0.5) break;
      final label = mmol ? (2 + 2 * k).toString() : (40 + 40 * k).toString();
      if (grid) _dotted(canvas, Offset(left, y(mg)), Offset(left + w, y(mg)), gridPaint);
      _text(canvas, label, Offset(left - 4, y(mg)), right: true);
    }

    // Vertical grid every [gridMin] minutes (set per graph button), dotted.
    // Time labels are spread so they never overlap.
    final stepSec = math.max(1, gridMin) * 60;
    final pxPerLine = stepSec / span * w;
    final labelEvery = math.max(1, (56 / math.max(pxPerLine, 1)).ceil());
    final day0 = DateTime(tStart.year, tStart.month, tStart.day);
    var n = (tStart.difference(day0).inSeconds / stepSec).ceil();
    for (var guard = 0; guard < 500; guard++, n++) {
      final t = day0.add(Duration(seconds: n * stepSec));
      if (!t.isBefore(tEnd)) break;
      final gx = x(t);
      if (grid) _dotted(canvas, Offset(gx, top), Offset(gx, plotBottom), gridPaint);
      final minutesOfDay = t.hour * 60 + t.minute;
      if ((minutesOfDay ~/ math.max(1, gridMin)) % labelEvery == 0) {
        _text(canvas, fmtClock(t, h24), Offset(gx, size.height - bottomLabels / 2), center: true);
      }
    }

    // Presets (Loop overrides, Trio temp targets): their target range shaded
    // over the time they run, a line along the top and their name.
    if (presets) {
      final list = treatments.where((t) => t.isPreset).toList()..sort((a, b) => a.t.compareTo(b.t));
      for (var i = 0; i < list.length; i++) {
        final p = list[i];
        final mins = p.duration ?? 0;
        if (mins <= 0 && !p.indefinite) continue; // a cancel
        var end = p.indefinite || mins > 60 * 24 * 7 ? tEnd : p.t.add(Duration(seconds: (mins * 60).round()));
        if (i + 1 < list.length && list[i + 1].t.isBefore(end)) end = list[i + 1].t;
        if (!end.isAfter(tStart) || p.t.isAfter(tEnd)) continue;
        final x1 = math.max(left, x(p.t));
        final x2 = math.min(left + w, x(end));
        if (x2 - x1 < 1) continue;
        if (p.targetLo != null && p.targetHi != null) {
          final yHi = y(math.max(p.targetHi!, p.targetLo! + 2));
          final yLo = y(p.targetLo!);
          canvas.drawRect(Rect.fromLTRB(x1, yHi, x2, yLo), Paint()..color = presetColor.withValues(alpha: 0.16));
        }
        canvas.drawRect(Rect.fromLTRB(x1, top, x2, top + 3), Paint()..color = presetColor);
        var name = p.reason.trim().isEmpty ? (p.type == 'Temporary Override' ? 'Override' : 'Temp target') : p.reason.trim();
        if (p.scale != null && (p.scale! - 1).abs() > 0.001) name += ' ${(p.scale! * 100).round()}%';
        final tp = TextPainter(
          text: TextSpan(
            text: name,
            style: TextStyle(color: presetColor, fontSize: presetSize, fontWeight: presetBold ? FontWeight.w700 : FontWeight.w500),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: math.max(0, x2 - x1 - 4));
        if (tp.width > 8) tp.paint(canvas, Offset(x1 + 3, top + 5));
      }
    }

    // Profile: its name at the bottom left, and a marker where it changed.
    final profs = profiles;
    if (profs != null && (profs.isNotEmpty || treatments.any((t) => t.type == 'Profile Switch'))) {
      final style = TextStyle(color: kMuted.withValues(alpha: 0.9), fontSize: 10);
      final cur = profileNameAt(treatments, profs, tStart.isAfter(now) ? now : tStart);
      if (cur.isNotEmpty) _text(canvas, 'Profile: $cur', Offset(left + 4, plotBottom - 8), color: style.color!);
      final pen = Paint()
        ..color = kMuted.withValues(alpha: 0.6)
        ..strokeWidth = 1;
      for (final ch in profileChanges(treatments, profs, tStart, tEnd)) {
        final cx = x(ch.key);
        _dotted(canvas, Offset(cx, top), Offset(cx, plotBottom), pen, on: 4, off: 3);
        _text(canvas, ch.value, Offset(cx + 3, plotBottom - 20), color: style.color!);
      }
    }

    // Now line.
    final nx = x(now);
    final dash = Paint()
      ..color = kMuted.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    for (var yy = top; yy < plotBottom; yy += 7) {
      canvas.drawLine(Offset(nx, yy), Offset(nx, math.min(yy + 3, plotBottom)), dash);
    }

    // Temp basal.
    if (showBasal) {
      final base = size.height - bottomLabels - 2;
      final segs = basalSegments(treatments, basalProfiles, tStart, now);
      var maxRate = 0.5;
      for (final g in segs) {
        maxRate = math.max(maxRate, g.rate);
      }
      final fill = Paint()..color = basalBar;
      // Scheduled basal (no temp basal running) a little lighter.
      final fillSched = Paint()..color = basalBar.withValues(alpha: basalBar.a * 0.55);
      final barMax = basalH - (basalLabels ? basalSize * 1.3 + 4 : 4);
      final runs = <List<double>>[]; // x1, x2, rate, bar top
      for (final g in segs) {
        final x1 = math.max(left, x(g.start));
        final x2 = math.min(left + w, x(g.end));
        if (x2 - x1 < 0.5) continue;
        final hh = g.rate / maxRate * barMax;
        canvas.drawRect(Rect.fromLTRB(x1, base - hh, x2, base), g.temp ? fill : fillSched);
        // Neighbouring bars with the same rate get one label.
        final r = (g.rate * 100).round() / 100;
        if (runs.isNotEmpty && runs.last[2] == r && (x1 - runs.last[1]).abs() < 1.5) {
          runs.last[1] = x2;
        } else {
          runs.add([x1, x2, r, base - hh]);
        }
      }
      // The rate (U/h) on top of each bar, where it fits.
      if (basalLabels) {
        for (final run in runs) {
          final label = run[2].toStringAsFixed(2);
          final tp = TextPainter(
            text: TextSpan(
              text: label,
              style: TextStyle(color: basalText, fontSize: basalSize, fontWeight: basalBold ? FontWeight.w700 : FontWeight.w400),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          if (run[1] - run[0] < tp.width + 4) continue;
          tp.paint(canvas, Offset((run[0] + run[1]) / 2 - tp.width / 2, run[3] - tp.height - 1));
        }
      }
      _text(canvas, 'basal', Offset(left + 2, base - basalH + 8), size: 9);
    }

    final hits = <_Hit>[];
    // Treatments: at the top of the graph, or on the glucose line at their time.
    if (showTreat) {
      double? bgAt(DateTime t) {
        Entry? best;
        var bestSec = 20 * 60;
        for (final e in visible) {
          final d = (e.t.difference(t).inSeconds).abs();
          if (d < bestSec) {
            bestSec = d;
            best = e;
          }
        }
        return best?.mg;
      }

      final fs = 9.5 * k;
      for (final t in treatments) {
        if (t.t.isAfter(tEnd)) continue;
        if (t.t.isBefore(tStart)) continue;
        final tx = x(t.t);
        final mg = treatOnLine ? bgAt(t.t) : null;
        final lineY = mg == null ? null : y(mg);
        if ((t.carbs ?? 0) > 0) {
          final r = 5 * k;
          // Top lane, or just under the glucose dot.
          final cy = lineY == null ? 8 * k : math.min(plotBottom - r, lineY + 6 * k + r);
          canvas.drawCircle(Offset(tx, cy), r, Paint()..color = kAmber);
          hits.add(_Hit(Offset(tx, cy), 'Carbs ${t.carbs!.round()} g', t.t));
          _text(canvas, '${t.carbs!.round()}g', Offset(tx, cy + r + fs * 0.75), color: kText, size: fs, center: true);
        }
        if ((t.insulin ?? 0) > 0) {
          if (t.isSmb) {
            final cy = lineY == null ? top - 3 * k : math.max(top, lineY - 5 * k);
            canvas.drawCircle(Offset(tx, cy), 2 * k, Paint()..color = kAccent);
            hits.add(_Hit(Offset(tx, cy), 'SMB ${fmtU(t.insulin!)} U', t.t));
          } else {
            final hw = 5 * k;
            final hh = 9 * k;
            // Triangle pointing down: top lane, or just above the glucose dot.
            final tipY = lineY == null ? 2 * k + hh : math.max(top, lineY - 5 * k);
            final p = Path()
              ..moveTo(tx - hw, tipY - hh)
              ..lineTo(tx + hw, tipY - hh)
              ..lineTo(tx, tipY)
              ..close();
            canvas.drawPath(p, Paint()..color = kAccent);
            hits.add(_Hit(Offset(tx, tipY - hh / 2), 'Bolus ${fmtU(t.insulin!)} U', t.t));
            final label = '${fmtU(t.insulin!)}U';
            if (lineY == null) {
              _text(canvas, label, Offset(tx + hw + 2, tipY - hh / 2), color: kText, size: fs);
            } else {
              _text(canvas, label, Offset(tx, tipY - hh - fs * 0.75), color: kText, size: fs, center: true);
            }
          }
        }
      }
    }

    // Prediction.
    if (pred.isNotEmpty && predStart != null) {
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = kMuted;
      for (var i = 0; i < pred.length; i++) {
        final t = predStart.add(Duration(minutes: 5 * i));
        if (t.isBefore(now) || t.isAfter(tEnd)) continue;
        canvas.drawCircle(Offset(x(t), y(pred[i])), 1.8 * dotScale, ring);
      }
    }

    // Glucose dots.
    // Small dots: thinner on long views. Size can be raised in settings.
    final rad = (hours <= 2 ? 1.9 : (hours <= 3 ? 1.7 : (hours <= 6 ? 1.5 : (hours <= 12 ? 1.25 : 1.0)))) * dotScale;
    for (final e in visible) {
      final er = activeRange(ranges, e.t);
      final c = brighten(zoneColorIn(zoneOf(e.mg, er), er), dotBright);
      canvas.drawCircle(Offset(x(e.t), y(e.mg)), rad, Paint()..color = c);
    }

    // Label for what is under the mouse (or finger).
    final hp = hover;
    if (hp != null && hp.dx >= left - 4 && hp.dx <= left + w + 4) {
      String? text;
      Offset? at;
      // A treatment marker close by wins.
      if (tipTreat != 0) {
        _Hit? best;
        var bd = 18.0 * math.max(1.0, k);
        for (final h in hits) {
          final d = (h.at - hp).distance;
          if (d < bd) {
            bd = d;
            best = h;
          }
        }
        if (best != null) {
          final tm = fmtClock(best.t, h24);
          text = tipTreat == 1 ? best.what : (tipTreat == 3 ? tm : '${best.what} · $tm');
          at = best.at;
        }
      }
      // Otherwise the reading closest in time to the mouse.
      if (text == null && tipBg != 0 && visible.isNotEmpty) {
        Entry? best;
        var bd = 14.0;
        for (final e in visible) {
          final d = (x(e.t) - hp.dx).abs();
          if (d < bd) {
            bd = d;
            best = e;
          }
        }
        if (best != null) {
          final v = '${fmtBg(best.mg, mmol)} ${unitLabel(mmol)}';
          final tm = fmtClock(best.t, h24);
          text = tipBg == 1 ? v : (tipBg == 3 ? tm : '$v · $tm');
          at = Offset(x(best.t), y(best.mg));
          canvas.drawCircle(at, rad + 3, Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = kText);
          _dotted(canvas, Offset(at.dx, top), Offset(at.dx, plotBottom), Paint()
            ..color = kMuted
            ..strokeWidth = 1);
        }
      }
      if (text != null && at != null) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: const TextStyle(color: kText, fontSize: 12.5, fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr,
        )..layout();
        const pad = 6.0;
        final bw = tp.width + pad * 2;
        final bh = tp.height + pad * 2;
        var bx = at.dx + 10;
        if (bx + bw > size.width - 2) bx = at.dx - 10 - bw;
        var by = at.dy - bh - 10;
        if (by < 2) by = at.dy + 10;
        bx = bx.clamp(2.0, math.max(2.0, size.width - bw - 2));
        by = by.clamp(2.0, math.max(2.0, size.height - bh - 2));
        final box = RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(6));
        canvas.drawRRect(box, Paint()..color = const Color(0xF01F2630));
        canvas.drawRRect(box, Paint()
          ..style = PaintingStyle.stroke
          ..color = kBorder);
        tp.paint(canvas, Offset(bx + pad, by + pad));
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// A small line graph for the night view.
class SparkLine extends StatelessWidget {
  final double height;
  final Color color;
  final int hours;
  const SparkLine({super.key, required this.height, required this.color, this.hours = 2});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _SparkPainter(app.entries, color, hours, app.range)),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<Entry> entries;
  final Color color;
  final int hours;
  final ZoneRange range;
  _SparkPainter(this.entries, this.color, this.hours, this.range);

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    final start = now.subtract(Duration(hours: hours));
    final pts = entries.where((e) => e.t.isAfter(start)).toList();
    const lo = 36.0;
    var hi = 270.0;
    for (final e in pts) {
      hi = math.max(hi, e.mg + 10);
    }
    double y(double mg) => size.height - (mg.clamp(lo, hi) - lo) / (hi - lo) * size.height;
    double x(DateTime t) => t.difference(start).inSeconds / (hours * 3600) * size.width;
    canvas.drawRect(Rect.fromLTRB(0, y(range.yelHi), size.width, y(range.yelLo)), Paint()..color = color.withValues(alpha: 0.08));
    final s = app.settings;
    final tightTop = s.number('ttirHi');
    if (s.flag('ttirOn') && tightTop > range.yelLo && tightTop < range.yelHi) {
      canvas.drawRect(Rect.fromLTRB(0, y(range.yelHi), size.width, y(tightTop)), Paint()..color = Color(s.integer('ttirColor')).withValues(alpha: 0.13));
    }
    if (pts.length < 2) return;
    final path = Path()..moveTo(x(pts.first.t), y(pts.first.mg));
    for (final e in pts.skip(1)) {
      path.lineTo(x(e.t), y(e.mg));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

const _gridChoices = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240];

String _fmtMinutes(int m) => m < 60 ? '$m min' : (m % 60 == 0 ? '${m ~/ 60} h' : '${m ~/ 60} h ${m % 60}');

/// Settings rows for the grid and the mouse-over labels (used in two screens).
List<Widget> graphGridSettings() {
  final buttons = app.graphButtons;
  final mins = gridMinutesList();
  void step(int i, int dir) {
    var k = _gridChoices.indexOf(mins[i]);
    if (k < 0) k = 2;
    k = (k + dir).clamp(0, _gridChoices.length - 1);
    final list = List<int>.from(mins);
    list[i] = _gridChoices[k];
    app.change((x) => x.set('gridMinutes', list));
  }

  const tips = ['Nothing', 'Value', 'Value and time', 'Time only'];
  return [
    setSwitch('Grid lines', 'gridLines', hint: 'Dotted lines across and down the graph'),
    setSwitch('Basal rate on the bars', 'basalLabels', hint: 'U/h written on top of the temp basal bars, where there is room'),
    StepRow(
      label: 'Basal numbers size',
      value: '${app.settings.number('basalTextSize').toStringAsFixed(app.settings.number('basalTextSize') % 1 == 0 ? 0 : 1)} px',
      onMinus: () => app.change((x) => x.set('basalTextSize', (x.number('basalTextSize') - 1).clamp(7.0, 30.0).roundToDouble())),
      onPlus: () => app.change((x) => x.set('basalTextSize', (x.number('basalTextSize') + 1).clamp(7.0, 30.0).roundToDouble())),
    ),
    setSwitch('Basal numbers bold', 'basalTextBold'),
    _colorRow('Basal numbers colour', 'basalTextColor'),
    _colorRow('Basal bars colour', 'basalBarColor'),
    setSwitch('Presets on the graph', 'presetShow', hint: 'Loop overrides and Trio temp targets: name, target range and time'),
    StepRow(
      label: 'Preset name size',
      value: '${app.settings.number('presetTextSize').round()} px',
      onMinus: () => app.change((x) => x.set('presetTextSize', (x.number('presetTextSize') - 1).clamp(7.0, 30.0).roundToDouble())),
      onPlus: () => app.change((x) => x.set('presetTextSize', (x.number('presetTextSize') + 1).clamp(7.0, 30.0).roundToDouble())),
    ),
    setSwitch('Preset name bold', 'presetBold'),
    _colorRow('Preset colour', 'presetColor'),
    for (var i = 0; i < 5 && i < buttons.length; i++)
      StepRow(
        label: 'Time lines on the ${buttons[i]} h graph',
        value: 'every ${_fmtMinutes(mins[i])}',
        onMinus: () => step(i, -1),
        onPlus: () => step(i, 1),
      ),
    setChoice('Mouse over a reading shows', 'tipBg', tips, hint: 'On a phone: tap, or touch and hold and slide'),
    setChoice('Mouse over a treatment shows', 'tipTreat', tips),
  ];
}

/// [c] made brighter (f > 1: more vivid and lighter) or dimmer (f < 1).
Color brighten(Color c, double f) {
  if ((f - 1).abs() < 0.01) return c;
  final h = HSLColor.fromColor(c);
  // Brighter = richer: full saturation and the colour's strongest lightness
  // (0.5), not whiter (which looks paler on a dark screen).
  final k = (f - 1).clamp(0.0, 1.0);
  final sat = f > 1 ? (h.saturation + (1 - h.saturation) * k).clamp(0.0, 1.0) : (h.saturation * f).clamp(0.0, 1.0);
  final light = f > 1 ? (h.lightness + (0.5 - h.lightness) * k).clamp(0.0, 1.0) : (h.lightness * f).clamp(0.05, 1.0);
  return h.withSaturation(sat).withLightness(light).toColor();
}

/// Settings rows for TTIR and the dots (used in two screens).
const kSoftColors = [0xFFFF4D5A, 0xFFF2C94C, 0xFF3DBE7A]; // red, yellow, green
const kBrightColors = [0xFFFF2020, 0xFFFFFF00, 0xFF4CFF00]; // like Nightscout

/// Soft or bright glucose colours, for every range (dots, value, graph).
Widget colourStyleRow() {
  final r = app.settings.ranges;
  bool all(List<int> c) => r.every((z) => z.cRed == c[0] && z.cYel == c[1] && z.cGreen == c[2]);
  final idx = all(kSoftColors) ? 0 : (all(kBrightColors) ? 1 : 2);
  return ChoiceRow(
    label: 'Glucose colours',
    hint: 'Bright: the strong red, yellow and green Nightscout uses',
    options: [ 'Soft', 'Bright', if (idx == 2) 'Your own'],
    index: idx,
    onChanged: (i) {
      if (i > 1) return;
      final c = i == 0 ? kSoftColors : kBrightColors;
      app.change((x) {
        for (final z in x.ranges) {
          z.cRed = c[0];
          z.cYel = c[1];
          z.cGreen = c[2];
        }
      });
    },
  );
}

List<Widget> ttirSettings() => [
      colourStyleRow(),
      setInt('Dot brightness', 'dotBright', step: 10, min: 50, max: 200, unit: '%', hint: 'Above 100 % makes the glucose dots brighter and more vivid'),
      setSwitch('Time in tight range (TTIR)', 'ttirOn',
          hint: 'Tints the part of your range above the tight range on graphs, and shows TTIR on reports and the main screen'),
      setChoice('Time in range card on the main screen', 'tirPeriod', const ['Today, since midnight', 'Last 24 hours']),
      setMg('Tight range up to', 'ttirHi', min: 100, max: 180, hint: 'Usual: 7.8 mmol/L (140 mg/dL). It starts at the low end of your range'),
      _colorRow('Colour above the tight range', 'ttirColor'),
      setSwitch('Profile on the graph', 'profileShow', hint: 'Name of the profile in use, and a line where it changed'),
    ];

Widget _colorRow(String label, String key) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(label, style: const TextStyle(fontSize: 15)),
        const SizedBox(height: 8),
        ColorPick(dot: 32, value: app.settings.integer(key), onPick: (v) => app.change((x) => x.set(key, v))),
      ]),
    );

/// One stretch of basal: a temp basal, or the profile's scheduled rate.
class BasalSeg {
  final DateTime start, end;
  final double rate;
  final bool temp;
  const BasalSeg(this.start, this.end, this.rate, this.temp);
}

/// Basal from [from] to [to]: the loop's temp basals and, between them, the
/// scheduled basal from the profile (as Nightscout draws it).
List<BasalSeg> basalSegments(List<Treatment> treatments, List<ProfileDoc> profiles, DateTime from, DateTime to) {
  final temps = treatments.where((t) => t.type == 'Temp Basal' || t.absolute != null).toList()..sort((a, b) => a.t.compareTo(b.t));
  final out = <BasalSeg>[];
  void scheduled(DateTime a, DateTime b) {
    if (profiles.isEmpty || !b.isAfter(a)) return;
    var t = a;
    while (t.isBefore(b)) {
      // Up to the next 30-minute mark (profile changes happen on those).
      final next30 = DateTime(t.year, t.month, t.day, t.hour, t.minute < 30 ? 30 : 60);
      final e = next30.isBefore(b) ? next30 : b;
      final r = profileAt(profiles, t)?.basalAt(t) ?? 0;
      if (out.isNotEmpty && !out.last.temp && out.last.rate == r && out.last.end == t) {
        out[out.length - 1] = BasalSeg(out.last.start, e, r, false);
      } else {
        out.add(BasalSeg(t, e, r, false));
      }
      t = e;
    }
  }

  var cursor = from;
  for (var i = 0; i < temps.length; i++) {
    final t = temps[i];
    final mins = t.duration ?? 0;
    var end = t.t.add(Duration(seconds: (mins * 60).round()));
    if (i + 1 < temps.length && temps[i + 1].t.isBefore(end)) end = temps[i + 1].t;
    if (!end.isAfter(from) || !t.t.isBefore(to)) continue;
    final s = t.t.isBefore(from) ? from : t.t;
    final e = end.isAfter(to) ? to : end;
    if (s.isAfter(cursor)) scheduled(cursor, s);
    if (mins > 0 && t.absolute != null && e.isAfter(s)) out.add(BasalSeg(s, e, t.absolute!, true));
    if (e.isAfter(cursor)) cursor = e;
  }
  if (to.isAfter(cursor)) scheduled(cursor, to);
  return out;
}
