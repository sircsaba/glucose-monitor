import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/data/nightscout.dart';
import 'package:glucose_monitor/logic/insulin.dart';

void main() {
  test('IOB and COB read from Loop and from AAPS/Trio uploads', () {
    final loop = statusPointOf({
      'created_at': '2026-11-19T15:00:00Z',
      'loop': {
        'timestamp': '2026-11-19T15:00:10Z',
        'iob': {'iob': 1.25},
        'cob': {'cob': 12.4},
      },
    })!;
    expect(loop.iob, 1.25);
    expect(loop.cob, 12.4);
    final aaps = statusPointOf({
      'created_at': '2026-11-19T15:05:00Z',
      'openaps': {
        'iob': [
          {'iob': 0.8},
        ],
        'suggested': {'COB': 5, 'timestamp': '2026-11-19T15:05:00Z'},
      },
    })!;
    expect(aaps.iob, 0.8);
    expect(aaps.cob, 5);
    expect(statusPointOf({'created_at': '2026-11-19T15:05:00Z', 'pump': {}}), isNull);
    final near = statusNear([loop, aaps], DateTime.parse('2026-11-19T15:04:00Z'));
    expect(near, same(aaps));
    expect(statusNear([loop], DateTime.parse('2026-11-19T16:00:00Z')), isNull);
  });

  test('basal at a moment: the temp basal while it runs', () {
    final t0 = DateTime(2026, 11, 19, 10);
    final ts = [Treatment(t: t0, type: 'Temp Basal', absolute: 0.35, duration: 30)];
    expect(basalRateAt(ts, const [], t0.add(const Duration(minutes: 10))), 0.35);
    expect(basalRateAt(ts, const [], t0.add(const Duration(minutes: 40))), isNull); // no profile
  });
}
