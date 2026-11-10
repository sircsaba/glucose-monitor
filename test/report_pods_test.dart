import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/data/nightscout.dart';
import 'package:glucose_monitor/logic/glucose.dart';
import 'package:glucose_monitor/logic/report.dart';
import 'package:glucose_monitor/ui/reports_screen.dart';

void main() {
  final t0 = DateTime(2026, 11, 1, 18);

  test('pods run from one change to the next, the last one until now', () {
    final ts = [
      Treatment(t: t0, type: 'Site Change'),
      Treatment(t: t0.add(const Duration(minutes: 5)), type: 'Pod Change'), // same pod
      Treatment(t: t0.add(const Duration(hours: 2)), type: 'Meal Bolus', insulin: 2),
      Treatment(t: t0.add(const Duration(days: 3)), type: 'Site Change'),
    ];
    final now = t0.add(const Duration(days: 4, hours: 1));
    final pods = podPeriods(podChanges(ts), now);
    expect(pods.length, 2);
    expect(pods[0].from, t0);
    expect(pods[0].to, t0.add(const Duration(days: 3)));
    expect(pods[0].current, false);
    expect(pods[1].current, true);
    expect(pods[1].to, now);
    expect(podLength(pods[0].length), '3 d 0 h');
    expect(podLength(pods[1].length), '1 d 1 h');
  });

  test('manual and automatic boluses are kept apart', () {
    final d = ReportData(
      from: t0,
      to: t0.add(const Duration(days: 1)),
      entries: const [],
      treatments: [
        Treatment(t: t0.add(const Duration(hours: 1)), type: 'Meal Bolus', insulin: 3),
        Treatment(t: t0.add(const Duration(hours: 2)), type: 'Correction Bolus', insulin: 0.4, isSmb: true),
      ],
      profiles: const [],
      lo: 70,
      hi: 180,
      tightHi: 140,
      ttirOn: false,
    );
    expect(d.ins.manualBolus, closeTo(3, 0.001));
    expect(d.ins.autoBolus, closeTo(0.4, 0.001));
  });

  test('daily stats: last row is the average per day, carbs per unit', () {
    final from = DateTime(2026, 11, 1);
    final d = ReportData(
      from: from,
      to: from.add(const Duration(days: 2)),
      entries: const [],
      treatments: [
        Treatment(t: from.add(const Duration(hours: 8)), type: 'Meal Bolus', insulin: 4, carbs: 60),
        Treatment(t: from.add(const Duration(hours: 32)), type: 'Meal Bolus', insulin: 2, carbs: 40),
      ],
      profiles: const [],
      lo: 70,
      hi: 180,
      tightHi: 140,
      ttirOn: false,
    );
    final rows = dailyStatsRows(d, false);
    final h = rows.first;
    final last = rows.last;
    expect(last.first, 'Average');
    expect(last[h.indexOf('Carbs')], '50');
    expect(last[h.indexOf('Manual bolus')], fmtU(3));
    expect(rows[1][h.indexOf('Carbs / U')], '15.0');
  });
}
