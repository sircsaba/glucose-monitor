import 'dart:math' as math;

import '../data/nightscout.dart';
import 'insulin.dart';
import 'profile.dart';

/// Glucose summary of a set of readings (all mg/dL, fractions 0–1).
class BgSummary {
  final int count;
  final double min, max, avg, sd, q25, median, q75;
  final double veryLow, low, tight, inRange, high, veryHigh;

  BgSummary({
    required this.count,
    required this.min,
    required this.max,
    required this.avg,
    required this.sd,
    required this.q25,
    required this.median,
    required this.q75,
    required this.veryLow,
    required this.low,
    required this.tight,
    required this.inRange,
    required this.high,
    required this.veryHigh,
  });

  double get below => veryLow + low;
  double get above => high + veryHigh;
  double get cv => avg == 0 ? 0 : sd / avg * 100;
  double get gmi => 3.31 + 0.02392 * avg;

  static BgSummary? of(List<double> v, double lo, double hi, double tightHi) {
    if (v.isEmpty) return null;
    final s = List<double>.from(v)..sort();
    final n = s.length;
    final avg = s.reduce((a, b) => a + b) / n;
    final sd = math.sqrt(s.map((x) => (x - avg) * (x - avg)).reduce((a, b) => a + b) / n);
    double frac(bool Function(double) f) => s.where(f).length / n;
    return BgSummary(
      count: n,
      min: s.first,
      max: s.last,
      avg: avg,
      sd: sd,
      q25: pct(s, .25),
      median: pct(s, .5),
      q75: pct(s, .75),
      veryLow: frac((x) => x < 54),
      low: frac((x) => x >= 54 && x < lo),
      tight: frac((x) => x >= lo && x <= tightHi),
      inRange: frac((x) => x >= lo && x <= hi),
      high: frac((x) => x > hi && x <= 250),
      veryHigh: frac((x) => x > 250),
    );
  }
}

double pct(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final i = (sorted.length - 1) * p;
  final lo = i.floor(), hi = i.ceil();
  return lo == hi ? sorted[lo] : sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo);
}

/// One row of the distribution table: readings within [from, to).
class RangeRow {
  final String name;
  final double from, to;
  final double share; // fraction of readings
  final int count;
  final double avg, median, sd;
  RangeRow(this.name, this.from, this.to, this.share, this.count, this.avg, this.median, this.sd);
}

class DayReport {
  final DateTime day;
  final List<Entry> entries;
  final BgSummary? bg;
  final InsulinTotals ins;
  final int lows; // low episodes (under the range for 15 min or more)
  DayReport(this.day, this.entries, this.bg, this.ins, this.lows);
}

/// Everything the reports show, worked out once for a period.
class ReportData {
  final DateTime from, to;
  final List<Entry> entries;
  final List<Treatment> treatments;
  final List<ProfileDoc> profiles;
  final double lo, hi, tightHi;
  final bool ttirOn;

  late final BgSummary? bg;
  late final List<DayReport> days;
  late final InsulinTotals ins;
  late final List<RangeRow> ranges;
  /// 24 hours, each [veryLow, low, tight, rest of range, high, veryHigh] fractions.
  late final List<List<double>> hourly;
  /// 48 half-hours, each [p5, p25, p50, p75, p95] (empty when no data).
  late final List<List<double>> agp;
  late final double lbgi, hbgi, gvi, pgs, dailyChange;
  late final int lowEpisodes;
  late final double sensorUse;

  ReportData({
    required this.from,
    required this.to,
    required this.entries,
    required this.treatments,
    required this.profiles,
    required this.lo,
    required this.hi,
    required this.tightHi,
    required this.ttirOn,
  }) {
    final vals = entries.map((e) => e.mg).toList();
    bg = BgSummary.of(vals, lo, hi, tightHi);
    ins = insulinTotals(treatments, profiles, from, to);

    // Days, newest first.
    final list = <DayReport>[];
    for (var d = DateTime(from.year, from.month, from.day); d.isBefore(to); d = DateTime(d.year, d.month, d.day + 1)) {
      final end = DateTime(d.year, d.month, d.day + 1);
      final a = d.isBefore(from) ? from : d;
      final b = end.isAfter(to) ? to : end;
      final es = entries.where((e) => !e.t.isBefore(a) && e.t.isBefore(b)).toList();
      list.add(DayReport(d, es, BgSummary.of(es.map((e) => e.mg).toList(), lo, hi, tightHi),
          insulinTotals(treatments, profiles, a, b), _lowEpisodes(es, lo)));
    }
    days = list.reversed.toList();

    // Distribution by range.
    RangeRow row(String name, double a, double b) {
      final v = vals.where((x) => x >= a && x < b).toList()..sort();
      if (v.isEmpty) return RangeRow(name, a, b, 0, 0, 0, 0, 0);
      final avg = v.reduce((p, q) => p + q) / v.length;
      final sd = math.sqrt(v.map((x) => (x - avg) * (x - avg)).reduce((p, q) => p + q) / v.length);
      return RangeRow(name, a, b, v.length / vals.length, v.length, avg, pct(v, .5), sd);
    }

    ranges = [
      row('Very low', 0, 54),
      row('Low', 54, lo),
      if (ttirOn) row('Tight range', lo, tightHi + 0.001),
      if (ttirOn) row('Range above tight', tightHi + 0.001, hi + 0.001) else row('In range', lo, hi + 0.001),
      row('High', hi + 0.001, 250.001),
      row('Very high', 250.001, 10000),
    ];

    // By hour of day.
    final buckets = List.generate(24, (_) => <double>[]);
    for (final e in entries) {
      buckets[e.t.hour].add(e.mg);
    }
    hourly = buckets.map((b) {
      if (b.isEmpty) return <double>[];
      final n = b.length;
      double f(bool Function(double) t) => b.where(t).length / n;
      return [
        f((x) => x < 54),
        f((x) => x >= 54 && x < lo),
        f((x) => x >= lo && x <= (ttirOn ? tightHi : hi)),
        ttirOn ? f((x) => x > tightHi && x <= hi) : 0.0,
        f((x) => x > hi && x <= 250),
        f((x) => x > 250),
      ];
    }).toList();

    final slots = List.generate(48, (_) => <double>[]);
    for (final e in entries) {
      slots[(e.t.hour * 60 + e.t.minute) ~/ 30].add(e.mg);
    }
    agp = slots.map((s) {
      if (s.isEmpty) return <double>[];
      s.sort();
      return [pct(s, .05), pct(s, .25), pct(s, .5), pct(s, .75), pct(s, .95)];
    }).toList();

    // Risk indexes (Kovatchev).
    var rl = 0.0, rh = 0.0;
    for (final v in vals) {
      final f = 1.509 * (math.pow(math.log(math.max(v, 20)), 1.084) - 5.381);
      final r = 10 * f * f;
      if (f < 0) {
        rl += r;
      } else {
        rh += r;
      }
    }
    lbgi = vals.isEmpty ? 0 : rl / vals.length;
    hbgi = vals.isEmpty ? 0 : rh / vals.length;

    // Variability on readings about 5 minutes apart (as Nightscout does).
    final thin = <Entry>[];
    for (final e in entries) {
      if (thin.isEmpty || e.t.difference(thin.last.t).inSeconds >= 270) thin.add(e);
    }
    var len = 0.0, ideal = 0.0, change = 0.0;
    for (var i = 1; i < thin.length; i++) {
      final dt = thin[i].t.difference(thin[i - 1].t).inSeconds / 60;
      if (dt <= 0 || dt > 15) continue;
      final dbg = thin[i].mg - thin[i - 1].mg;
      len += math.sqrt(dt * dt + dbg * dbg);
      ideal += dt;
      change += dbg.abs();
    }
    gvi = ideal == 0 ? 0 : len / ideal;
    pgs = bg == null ? 0 : gvi * bg!.avg * (1 - bg!.inRange);
    final nDays = math.max(1.0, to.difference(from).inMinutes / 1440);
    dailyChange = change / nDays;
    lowEpisodes = days.fold(0, (a, d) => a + d.lows);

    // Sensor use: readings received out of those expected (1 or 5 min apart).
    final gaps = <int>[];
    for (var i = 1; i < entries.length && i < 300; i++) {
      gaps.add(entries[i].t.difference(entries[i - 1].t).inSeconds);
    }
    gaps.sort();
    final interval = gaps.isEmpty ? 300 : math.max(60, gaps[gaps.length ~/ 2]);
    sensorUse = math.min(1.0, entries.length / (to.difference(from).inSeconds / interval));
  }

  int get dayCount => days.length;

  /// Daily averages over the days with data.
  double get avgCarbs => _avg((d) => d.ins.carbs);
  double get avgTdd => _avg((d) => d.ins.total);
  double get avgBolus => _avg((d) => d.ins.bolus);
  double get avgBasal => _avg((d) => d.ins.totalBasal);

  double _avg(double Function(DayReport) f) {
    final full = days.where((d) => d.ins.hours >= 23).toList();
    final use = full.isEmpty ? days : full;
    if (use.isEmpty) return 0;
    return use.map(f).reduce((a, b) => a + b) / use.length;
  }
}

int _lowEpisodes(List<Entry> es, double lo) {
  var n = 0;
  DateTime? start;
  var counted = false;
  for (final e in es) {
    if (e.mg < lo) {
      start ??= e.t;
      if (!counted && e.t.difference(start).inMinutes >= 15) {
        n++;
        counted = true;
      }
    } else {
      start = null;
      counted = false;
    }
  }
  return n;
}
