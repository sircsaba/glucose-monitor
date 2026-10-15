import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/nightscout.dart';
import '../logic/glucose.dart';
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
    Widget chart = SizedBox(
      height: widget.height,
      width: double.infinity,
      child: CustomPaint(
        painter: _BgPainter(
          entries: app.entries,
          treatments: app.treatments,
          device: app.device,
          ranges: s.ranges,
          mmol: s.mmol,
          hours: widget.hours,
          showPred: s.flag('showPrediction'),
          showBasal: s.flag('showBasal'),
          showTreat: s.flag('showTreatments'),
          h24: s.flag('time24'),
          now: DateTime.now(),
          topMg: s.number('graphTop'),
          dotScale: const [1.0, 1.4, 1.9][s.integer('dotSize').clamp(0, 2)],
          treatScale: (s.integer('treatSize') / 100.0).clamp(0.5, 3.0),
          treatOnLine: s.integer('treatPlace') == 1,
          grid: s.flag('gridLines'),
          gridMin: gridMin,
          hover: _pos,
          tipBg: tipBg,
          tipTreat: tipTreat,
        ),
      ),
    );
    if (tipBg == 0 && tipTreat == 0) return chart;
    return MouseRegion(
      onHover: (e) => _show(e.localPosition),
      onExit: (_) => _show(null),
      child: GestureDetector(
        onTapDown: (d) => _show(d.localPosition, autoHide: true),
        onLongPressStart: (d) => _show(d.localPosition),
        onLongPressMoveUpdate: (d) => _show(d.localPosition),
        onLongPressEnd: (d) => _show(d.localPosition, autoHide: true),
        child: chart,
      ),
    );
  }
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
  final int gridMin;
  final Offset? hover;
  final int tipBg; // 0 nothing, 1 value, 2 value and time, 3 time
  final int tipTreat;

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
    required this.gridMin,
    required this.hover,
    required this.tipBg,
    required this.tipTreat,
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
    final basalH = showBasal ? 30.0 : 0.0;
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

    final visible = entries.where((e) => e.t.isAfter(tStart)).toList();
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
    // Green band and zone lines, in this range's colours.
    canvas.drawRect(Rect.fromLTRB(left, y(r.yelHi), left + w, y(r.yelLo)), Paint()..color = Color(r.cGreen).withValues(alpha: 0.08));
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
      final temps = treatments.where((t) => t.absolute != null && (t.duration ?? 0) > 0).toList();
      var maxRate = 0.5;
      for (final t in temps) {
        maxRate = math.max(maxRate, t.absolute!);
      }
      final fill = Paint()..color = const Color(0xFF2B4A63);
      for (var i = 0; i < temps.length; i++) {
        final t = temps[i];
        var end = t.t.add(Duration(seconds: (t.duration! * 60).round()));
        if (i + 1 < temps.length && temps[i + 1].t.isBefore(end)) end = temps[i + 1].t;
        if (end.isBefore(tStart) || t.t.isAfter(tEnd)) continue;
        final x1 = math.max(left, x(t.t));
        final x2 = math.min(left + w, x(end));
        final hh = t.absolute! / maxRate * (basalH - 4);
        canvas.drawRect(Rect.fromLTRB(x1, base - hh, x2, base), fill);
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
            hits.add(_Hit(Offset(tx, cy), 'SMB ${t.insulin!.toStringAsFixed(2)} U', t.t));
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
            hits.add(_Hit(Offset(tx, tipY - hh / 2), 'Bolus ${t.insulin!.toStringAsFixed(2)} U', t.t));
            final label = '${t.insulin!.toStringAsFixed(1)}U';
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
      final c = zoneColorIn(zoneOf(e.mg, er), er);
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
