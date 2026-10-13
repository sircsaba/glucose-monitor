import 'dart:math' as math;

import '../data/nightscout.dart';

class GlucoseStats {
  final int count;
  final double avg; // mg/dL
  final double cv; // %
  final double gmi; // %
  final double below; // fraction
  final double inRange;
  final double above;
  final double sensorUse; // fraction of expected readings
  /// 48 half-hour slots, each [p5, p25, p50, p75, p95] in mg/dL (empty if no data).
  final List<List<double>> agp;
  final List<DayTir> days;

  GlucoseStats({
    required this.count,
    required this.avg,
    required this.cv,
    required this.gmi,
    required this.below,
    required this.inRange,
    required this.above,
    required this.sensorUse,
    required this.agp,
    required this.days,
  });
}

class DayTir {
  final DateTime day;
  final double below;
  final double inRange;
  final double above;
  DayTir(this.day, this.below, this.inRange, this.above);
}

double _pct(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final i = (sorted.length - 1) * p;
  final lo = i.floor();
  final hi = i.ceil();
  if (lo == hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo);
}

GlucoseStats? computeStats(List<Entry> entries, double lo, double hi, int days) {
  if (entries.isEmpty) return null;
  final vals = entries.map((e) => e.mg).toList();
  final n = vals.length;
  final avg = vals.reduce((a, b) => a + b) / n;
  final varc = vals.map((v) => (v - avg) * (v - avg)).reduce((a, b) => a + b) / n;
  final sd = math.sqrt(varc);
  final below = vals.where((v) => v < lo).length / n;
  final above = vals.where((v) => v > hi).length / n;

  // Expected readings: work out the sensor interval from the data (1 or 5 min).
  var gaps = <int>[];
  for (var i = 1; i < entries.length && i < 200; i++) {
    gaps.add(entries[i].t.difference(entries[i - 1].t).inSeconds);
  }
  gaps.sort();
  final interval = gaps.isEmpty ? 300 : math.max(60, gaps[gaps.length ~/ 2]);
  final expected = days * 86400 / interval;

  final slots = List.generate(48, (_) => <double>[]);
  for (final e in entries) {
    slots[(e.t.hour * 60 + e.t.minute) ~/ 30].add(e.mg);
  }
  final agp = slots.map((s) {
    if (s.isEmpty) return <double>[];
    s.sort();
    return [_pct(s, .05), _pct(s, .25), _pct(s, .5), _pct(s, .75), _pct(s, .95)];
  }).toList();

  final byDay = <DateTime, List<double>>{};
  for (final e in entries) {
    final d = DateTime(e.t.year, e.t.month, e.t.day);
    byDay.putIfAbsent(d, () => []).add(e.mg);
  }
  final dayList = byDay.keys.toList()..sort();
  final dayTir = dayList.map((d) {
    final v = byDay[d]!;
    final b = v.where((x) => x < lo).length / v.length;
    final a = v.where((x) => x > hi).length / v.length;
    return DayTir(d, b, 1 - a - b, a);
  }).toList();

  return GlucoseStats(
    count: n,
    avg: avg,
    cv: avg == 0 ? 0 : sd / avg * 100,
    gmi: 3.31 + 0.02392 * avg,
    below: below,
    inRange: 1 - below - above,
    above: above,
    sensorUse: math.min(1.0, n / expected),
    agp: agp,
    days: dayTir,
  );
}
