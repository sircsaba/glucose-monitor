import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/data/nightscout.dart';
import 'package:glucose_monitor/logic/insulin.dart';
import 'package:glucose_monitor/logic/profile.dart';
import 'package:glucose_monitor/logic/report.dart';

void main() {
  final day = DateTime(2026, 10, 16);
  final profiles = parseProfiles([
    {
      'defaultProfile': 'Default',
      'startDate': DateTime(2026, 10, 1).toUtc().toIso8601String(),
      'store': {
        'Default': {
          'units': 'mmol/L',
          'basal': [
            {'time': '00:00', 'value': 1.0},
            {'time': '06:00', 'timeAsSeconds': 21600, 'value': 0.5},
          ],
          'carbratio': [
            {'time': '00:00', 'value': 10},
          ],
          'sens': [
            {'time': '00:00', 'value': 2.5},
          ],
        },
      },
    },
  ]);

  test('profile parsed, ISF in mg/dL', () {
    expect(profiles.length, 1);
    expect(profiles.first.name, 'Default');
    expect(profiles.first.basalAt(day.add(const Duration(hours: 3))), 1.0);
    expect(profiles.first.basalAt(day.add(const Duration(hours: 7))), 0.5);
    expect(profiles.first.sensAt(day)!.round(), 45);
    expect(profiles.first.dailyBasal, 6 * 1.0 + 18 * 0.5);
  });

  test('insulin totals with a temp basal, boluses and carbs', () {
    final tr = [
      Treatment(t: day.add(const Duration(hours: 2)), type: 'Temp Basal', absolute: 2.0, duration: 60),
      Treatment(t: day.add(const Duration(hours: 4)), type: 'Temp Basal', absolute: 0.0, duration: 30),
      Treatment(t: day.add(const Duration(hours: 8)), type: 'Meal Bolus', insulin: 3, carbs: 30),
      Treatment(t: day.add(const Duration(hours: 9)), type: 'Correction Bolus', insulin: 0.5, isSmb: true),
    ];
    final t = insulinTotals(tr, profiles, day, day.add(const Duration(hours: 12)));
    expect(t.baseBasal, closeTo(6 * 1.0 + 6 * 0.5, 0.01));
    expect(t.tempPlus, closeTo(1.0, 0.01));
    expect(t.tempMinus, closeTo(-0.5, 0.01));
    expect(t.totalBasal, closeTo(9.5, 0.01));
    expect(t.bolus, 3.5);
    expect(t.autoBolus, 0.5);
    expect(t.carbs, 30);
    expect(t.icrManual, closeTo(10, 0.01));
    expect(t.total, closeTo(13, 0.01));
  });

  test('report summary ranges', () {
    final es = [for (var i = 0; i < 100; i++) Entry(day.add(Duration(minutes: 5 * i)), i < 10 ? 60 : (i < 70 ? 120 : 200), '')];
    final r = ReportData(
      from: day,
      to: day.add(const Duration(hours: 9)),
      entries: es,
      treatments: const [],
      profiles: profiles,
      lo: 70,
      hi: 180,
      tightHi: 140,
      ttirOn: true,
    );
    expect(r.bg!.low, closeTo(0.10, 0.001));
    expect(r.bg!.tight, closeTo(0.60, 0.001));
    expect(r.bg!.inRange, closeTo(0.60, 0.001));
    expect(r.bg!.high, closeTo(0.30, 0.001));
    expect(r.lowEpisodes, 1);
    expect(r.days.length, 1);
  });
}
