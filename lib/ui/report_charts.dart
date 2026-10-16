import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/nightscout.dart';
import '../logic/glucose.dart';
import '../logic/insulin.dart';
import '../logic/profile.dart';
import '../logic/report.dart';
import '../state/settings.dart';

/// Colours for charts: dark on screen, light for printing.
class ChartTheme {
  final Color text, muted, grid, bg;
  const ChartTheme(this.text, this.muted, this.grid, this.bg);
  static const dark = ChartTheme(Color(0xFFE6EDF3), Color(0xFF9AA4B2), Color(0xFF2A313C), Color(0x00000000));
  static const light = ChartTheme(Color(0xFF1A1A1A), Color(0xFF666666), Color(0xFFDDDDDD), Color(0xFFFFFFFF));
}

/// Range colours used by every report.
class RangeColors {
  static const veryLow = Color(0xFFC62834);
  static const low = kRed;
  static const tight = kGreen;
  static const high = Color(0xFFF5A623);
  static const veryHigh = Color(0xFFD35400);
  static const bolus = Color(0xFF3D7BF7);
  static const autoBolus = Color(0xFF8AB4FF);
  static const carbs = Color(0xFFFF9F43);
  static const basal = Color(0xFF5BC0EB);
}

Color colorFor(double mg, double lo, double hi) {
  if (mg < 54) return RangeColors.veryLow;
  if (mg < lo) return RangeColors.low;
  if (mg > 250) return RangeColors.veryHigh;
  if (mg > hi) return RangeColors.high;
  return RangeColors.tight;
}

void _label(Canvas c, String s, Offset at, Color color, {double size = 10, bool center = false, bool right = false, bool bold = false}) {
  final tp = TextPainter(
    text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
    textDirection: TextDirection.ltr,
  )..layout();
  var dx = at.dx;
  if (center) dx -= tp.width / 2;
  if (right) dx -= tp.width;
  tp.paint(c, Offset(dx, at.dy - tp.height / 2));
}

/// One day, Nightscout "Day to day" style: readings, boluses, carbs, basal
/// (scheduled dashed, delivered filled) and profile changes over 24 hours.
class DayChartPainter extends CustomPainter {
  final DateTime day;
  final List<Entry> entries;
  final List<Treatment> treatments;
  final List<ProfileDoc> profiles;
  final double lo, hi;
  final double? tightHi;
  final Color tightColor;
  final bool mmol;
  final ChartTheme theme;

  DayChartPainter({
    required this.day,
    required this.entries,
    required this.treatments,
    required this.profiles,
    required this.lo,
    required this.hi,
    required this.tightHi,
    required this.tightColor,
    required this.mmol,
    required this.theme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (theme.bg.a > 0) canvas.drawRect(Offset.zero & size, Paint()..color = theme.bg);
    const left = 30.0, right = 6.0, bottomLabels = 16.0;
    final w = size.width - left - right;
    final basalH = size.height * 0.2;
    final top = 6.0;
    final plotBottom = size.height - bottomLabels - basalH - 6;
    final plotH = plotBottom - top;
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day + 1);
    double x(DateTime t) => left + t.difference(start).inSeconds / 86400 * w;

    final step = mmol ? 2 * mgPerMmol : 40.0;
    final minMg = mmol ? 2 * mgPerMmol : 40.0;
    var maxMg = mmol ? 12 * mgPerMmol : 240.0;
    for (final e in entries) {
      if (e.mg + 5 > maxMg) maxMg = e.mg + 5;
    }
    maxMg = minMg + ((maxMg - minMg) / step).ceil() * step;
    double y(double mg) => top + (1 - (mg.clamp(minMg, maxMg) - minMg) / (maxMg - minMg)) * plotH;

    // Range band, tight part, grid.
    final th = tightHi;
    if (th != null && th > lo && th < hi) {
      canvas.drawRect(Rect.fromLTRB(left, y(th), left + w, y(lo)), Paint()..color = kGreen.withValues(alpha: 0.12));
      canvas.drawRect(Rect.fromLTRB(left, y(hi), left + w, y(th)), Paint()..color = tightColor.withValues(alpha: 0.25));
    } else {
      canvas.drawRect(Rect.fromLTRB(left, y(hi), left + w, y(lo)), Paint()..color = kGreen.withValues(alpha: 0.12));
    }
    final grid = Paint()
      ..color = theme.grid
      ..strokeWidth = 1;
    for (var mg = minMg; mg <= maxMg + 0.5; mg += step) {
      canvas.drawLine(Offset(left, y(mg)), Offset(left + w, y(mg)), grid);
      _label(canvas, mmol ? (mg / mgPerMmol).round().toString() : mg.round().toString(), Offset(left - 4, y(mg)), theme.muted, right: true);
    }
    for (var h = 0; h <= 24; h += 3) {
      final gx = left + h / 24 * w;
      canvas.drawLine(Offset(gx, top), Offset(gx, size.height - bottomLabels), grid);
      _label(canvas, '${h.toString().padLeft(2, '0')}h', Offset(gx, size.height - bottomLabels / 2), theme.muted, center: true);
    }

    // Boluses: bars up from the bottom of the glucose area.
    final dayT = treatments.where((t) => !t.t.isBefore(start) && t.t.isBefore(end)).toList();
    for (final t in dayT) {
      final u = t.insulin ?? 0;
      if (u <= 0 || t.type == 'Temp Basal') continue;
      final bh = math.min(plotH * 0.45, u / 10 * plotH * 0.45 + 2);
      final bx = x(t.t);
      canvas.drawRect(Rect.fromLTRB(bx - 1.5, plotBottom - bh, bx + 1.5, plotBottom),
          Paint()..color = t.isSmb ? RangeColors.autoBolus : RangeColors.bolus);
      if (!t.isSmb && u >= 0.5) _label(canvas, '${fmtU(u)}U', Offset(bx + 3, plotBottom - bh - 6), RangeColors.bolus, size: 9);
    }
    // Carbs: a dot at the top with the grams.
    for (final t in dayT) {
      final g = t.carbs ?? 0;
      if (g <= 0) continue;
      final cx = x(t.t);
      canvas.drawCircle(Offset(cx, top + 8), 4, Paint()..color = RangeColors.carbs);
      _label(canvas, '${g.round()}g', Offset(cx + 6, top + 8), RangeColors.carbs, size: 9, bold: true);
    }

    // Readings.
    for (final e in entries) {
      canvas.drawCircle(Offset(x(e.t), y(e.mg)), 1.7, Paint()..color = colorFor(e.mg, lo, hi));
    }

    // Profile changes.
    for (final ch in profileChanges(treatments, profiles, start, end)) {
      final cx = x(ch.key);
      for (var yy = top; yy < plotBottom; yy += 7) {
        canvas.drawLine(Offset(cx, yy), Offset(cx, math.min(yy + 4, plotBottom)), Paint()..color = theme.muted);
      }
      _label(canvas, ch.value, Offset(cx + 3, plotBottom - 20), theme.muted, size: 9);
    }

    // Basal: scheduled (dashed) and delivered (filled), in its own strip.
    final bTop = plotBottom + 6;
    final bBottom = bTop + basalH - 4;
    final temps = dayT.isEmpty ? <Treatment>[] : treatments.where((t) => t.type == 'Temp Basal' && t.absolute != null).toList();
    final sched = <double>[];
    final actual = <double>[];
    var k = 0;
    for (var m = 0; m < 1440; m += 5) {
      final t = start.add(Duration(minutes: m));
      final s = profileAt(profiles, t)?.basalAt(t) ?? 0;
      while (k + 1 < temps.length && !temps[k + 1].t.isAfter(t)) {
        k++;
      }
      var r = s;
      if (temps.isNotEmpty && !temps[k].t.isAfter(t)) {
        final tb = temps[k];
        if (t.isBefore(tb.t.add(Duration(seconds: ((tb.duration ?? 30) * 60).round())))) r = tb.absolute!;
      }
      sched.add(s);
      actual.add(r);
    }
    final now = DateTime.now();
    final maxRate = math.max(0.5, [...sched, ...actual].fold(0.0, math.max) * 1.15);
    double by(double r) => bBottom - r / maxRate * (bBottom - bTop);
    final area = Path()..moveTo(left, bBottom);
    for (var i = 0; i < actual.length; i++) {
      final t = start.add(Duration(minutes: i * 5));
      if (t.isAfter(now)) break;
      final x1 = left + i / actual.length * w, x2 = left + (i + 1) / actual.length * w;
      area.lineTo(x1, by(actual[i]));
      area.lineTo(x2, by(actual[i]));
      if (i == actual.length - 1 || start.add(Duration(minutes: (i + 1) * 5)).isAfter(now)) area.lineTo(x2, bBottom);
    }
    area.close();
    canvas.drawPath(area, Paint()..color = RangeColors.basal.withValues(alpha: 0.35));
    final dash = Paint()
      ..color = RangeColors.basal
      ..strokeWidth = 1.2;
    for (var i = 0; i < sched.length; i++) {
      final x1 = left + i / sched.length * w, x2 = left + (i + 1) / sched.length * w;
      if (i % 2 == 0) canvas.drawLine(Offset(x1, by(sched[i])), Offset(x2, by(sched[i])), dash);
    }
    _label(canvas, 'basal', Offset(left - 4, (bTop + bBottom) / 2), theme.muted, size: 9, right: true);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class PieSlice {
  final double value;
  final Color color;
  final String label;
  const PieSlice(this.value, this.color, this.label);
}

/// Pie with the percentage written on each slice big enough to hold it.
class PiePainter extends CustomPainter {
  final List<PieSlice> slices;
  final String? center; // text in the middle (donut)
  final ChartTheme theme;
  PiePainter(this.slices, {this.center, this.theme = ChartTheme.dark});

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold(0.0, (a, s) => a + s.value);
    final r = math.min(size.width, size.height) / 2 - 2;
    final c = Offset(size.width / 2, size.height / 2);
    if (total <= 0) {
      canvas.drawCircle(c, r, Paint()..color = theme.grid);
      return;
    }
    var a0 = -math.pi / 2;
    for (final s in slices) {
      if (s.value <= 0) continue;
      final sweep = s.value / total * 2 * math.pi;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a0, sweep, true, Paint()..color = s.color);
      a0 += sweep;
    }
    final hole = center != null;
    if (hole) canvas.drawCircle(c, r * 0.55, Paint()..color = theme.bg.a > 0 ? theme.bg : const Color(0xFF161B22));
    a0 = -math.pi / 2;
    for (final s in slices) {
      if (s.value <= 0) continue;
      final sweep = s.value / total * 2 * math.pi;
      final p = s.value / total * 100;
      if (p >= 5) {
        final mid = a0 + sweep / 2;
        final rr = hole ? r * 0.78 : r * 0.62;
        _label(canvas, '${p.round()}%', c + Offset(math.cos(mid) * rr, math.sin(mid) * rr), const Color(0xFF111111),
            size: math.max(9, r * 0.16), center: true, bold: true);
      }
      a0 += sweep;
    }
    if (hole) _label(canvas, center!, c, theme.text, size: math.max(10, r * 0.24), center: true, bold: true);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// 24 stacked bars: share of time in each range by hour of day.
class HourlyPainter extends CustomPainter {
  final List<List<double>> hourly;
  final List<Color> colors; // veryLow, low, tight, restOfRange, high, veryHigh
  final ChartTheme theme;
  HourlyPainter(this.hourly, this.colors, {this.theme = ChartTheme.dark});

  @override
  void paint(Canvas canvas, Size size) {
    if (theme.bg.a > 0) canvas.drawRect(Offset.zero & size, Paint()..color = theme.bg);
    const left = 30.0, bottom = 16.0;
    final w = size.width - left - 4;
    final h = size.height - bottom - 4;
    for (final p in [0, 25, 50, 75, 100]) {
      final yy = 4 + h * (1 - p / 100);
      canvas.drawLine(Offset(left, yy), Offset(left + w, yy), Paint()..color = theme.grid);
      _label(canvas, '$p%', Offset(left - 4, yy), theme.muted, right: true, size: 9);
    }
    final bw = w / 24;
    for (var i = 0; i < 24; i++) {
      final f = i < hourly.length ? hourly[i] : const <double>[];
      var yy = 4 + h;
      for (var k = 0; k < f.length && k < colors.length; k++) {
        final bh = f[k] * h;
        if (bh <= 0) continue;
        canvas.drawRect(Rect.fromLTRB(left + i * bw + 1, yy - bh, left + (i + 1) * bw - 1, yy), Paint()..color = colors[k]);
        yy -= bh;
      }
      if (i % 3 == 0) _label(canvas, '${i.toString().padLeft(2, '0')}h', Offset(left + i * bw + bw / 2, size.height - bottom / 2), theme.muted, center: true, size: 9);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Glucose profile by time of day: 5–95 % and 25–75 % bands and the median.
class AgpPainter extends CustomPainter {
  final List<List<double>> agp;
  final double lo, hi;
  final double? tightHi;
  final Color tightColor;
  final bool mmol;
  final ChartTheme theme;
  AgpPainter(this.agp, this.lo, this.hi, this.mmol, {this.tightHi, this.tightColor = const Color(0xFFFFF3A0), this.theme = ChartTheme.dark});

  @override
  void paint(Canvas canvas, Size size) {
    if (theme.bg.a > 0) canvas.drawRect(Offset.zero & size, Paint()..color = theme.bg);
    const left = 26.0, bottom = 16.0;
    final w = size.width - left - 4;
    final h = size.height - bottom;
    var maxMg = 270.0;
    for (final a in agp) {
      if (a.isNotEmpty) maxMg = math.max(maxMg, a[4] + 10);
    }
    const minMg = 36.0;
    double y(double mg) => (1 - (mg - minMg) / (maxMg - minMg)) * h;
    double x(int slot) => left + (slot + 0.5) / 48 * w;
    canvas.drawRect(Rect.fromLTRB(left, y(hi), left + w, y(lo)), Paint()..color = kGreen.withValues(alpha: 0.10));
    final th = tightHi;
    if (th != null && th > lo && th < hi) {
      canvas.drawRect(Rect.fromLTRB(left, y(hi), left + w, y(th)), Paint()..color = tightColor.withValues(alpha: 0.2));
    }
    void band(int a, int b, Color c) {
      final path = Path();
      var started = false;
      for (var i = 0; i < 48; i++) {
        if (agp[i].isEmpty) continue;
        final p = Offset(x(i), y(agp[i][b]));
        if (!started) {
          path.moveTo(p.dx, p.dy);
          started = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      for (var i = 47; i >= 0; i--) {
        if (agp[i].isEmpty) continue;
        path.lineTo(x(i), y(agp[i][a]));
      }
      if (started) {
        path.close();
        canvas.drawPath(path, Paint()..color = c);
      }
    }

    final light = theme.bg.a > 0;
    band(0, 4, light ? const Color(0xFFBFD9E8) : const Color(0xFF1D3A4A));
    band(1, 3, light ? const Color(0xFF6FA8C8) : const Color(0xFF2E6A86));
    final med = Path();
    var started = false;
    for (var i = 0; i < 48; i++) {
      if (agp[i].isEmpty) continue;
      if (!started) {
        med.moveTo(x(i), y(agp[i][2]));
        started = true;
      } else {
        med.lineTo(x(i), y(agp[i][2]));
      }
    }
    canvas.drawPath(
      med,
      Paint()
        ..color = theme.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (final hr in [0, 3, 6, 9, 12, 15, 18, 21, 24]) {
      _label(canvas, '${hr.toString().padLeft(2, '0')}h', Offset(left + hr / 24 * w, h + 8), theme.muted, center: true);
    }
    for (final g in (mmol ? [4.0, 7.8, 10.0, 14.0] : [70.0, 140.0, 180.0, 250.0])) {
      final mg = mmol ? g * mgPerMmol : g;
      if (mg > maxMg) continue;
      _label(canvas, mmol ? g.toString() : g.toStringAsFixed(0), Offset(left - 4, y(mg)), theme.muted, right: true);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// The range colours in order, with the TTIR colour when TTIR is on.
List<Color> rangeColorList(Color tightColor, bool ttirOn) => [
      RangeColors.veryLow,
      RangeColors.low,
      RangeColors.tight,
      ttirOn ? tightColor : RangeColors.tight,
      RangeColors.high,
      RangeColors.veryHigh,
    ];

/// Pie slices for time in ranges.
List<PieSlice> rangeSlices(BgSummary b, Color tightColor, bool ttirOn) => [
      PieSlice(b.veryLow, RangeColors.veryLow, 'Very low'),
      PieSlice(b.low, RangeColors.low, 'Low'),
      if (ttirOn) PieSlice(b.tight, RangeColors.tight, 'Tight range'),
      if (ttirOn) PieSlice(b.inRange - b.tight, tightColor, 'Range above tight') else PieSlice(b.inRange, RangeColors.tight, 'In range'),
      PieSlice(b.high, RangeColors.high, 'High'),
      PieSlice(b.veryHigh, RangeColors.veryHigh, 'Very high'),
    ];
