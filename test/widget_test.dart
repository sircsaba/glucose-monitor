import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/data/nightscout.dart';
import 'package:glucose_monitor/logic/glucose.dart';
import 'package:glucose_monitor/state/settings.dart';

void main() {
  test('zones follow the four limits', () {
    final r = ZoneRange(name: 'Day', from: 420, to: 1260, days: List.filled(7, true), redLo: 63, yelLo: 81, yelHi: 180, redHi: 234);
    expect(zoneOf(55, r), Zone.redLow);
    expect(zoneOf(70, r), Zone.yellowLow);
    expect(zoneOf(120, r), Zone.green);
    expect(zoneOf(200, r), Zone.yellowHigh);
    expect(zoneOf(300, r), Zone.redHigh);
  });

  test('a night range crosses midnight', () {
    final n = ZoneRange(name: 'Night', from: 1260, to: 420, days: List.filled(7, true), redLo: 72, yelLo: 90, yelHi: 198, redHi: 252);
    expect(n.covers(DateTime(2026, 10, 12, 23, 0)), true);
    expect(n.covers(DateTime(2026, 10, 13, 3, 0)), true);
    expect(n.covers(DateTime(2026, 10, 13, 12, 0)), false);
  });

  test('average change over 5 minutes', () {
    final t = DateTime(2026, 10, 12, 22, 0);
    final e = [
      Entry(t, 100, 'Flat'),
      Entry(t.add(const Duration(minutes: 5)), 110, 'Flat'),
    ];
    expect(avgDelta5(e)!.round(), 10);
  });

  test('settings survive saving and loading', () {
    final s = Settings.initial();
    s.set('nightBrightness', 25);
    s.snoozePresets = [5, 15];
    final back = Settings.decode(s.encode());
    expect(back.integer('nightBrightness'), 25);
    expect(back.snoozePresets, [5, 15]);
    expect(back.lines.length, s.lines.length);
  });

  test('mmol formatting', () {
    expect(fmtBg(126, true), '7.0');
    expect(fmtBg(126, false), '126');
  });
}
