import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/ui/screen_saver.dart';

void main() {
  bool on(DateTime now, {bool endOn = false, DateTime? dismissed}) =>
      screenSaverScheduled(on: true, from: 480, endOn: endOn, to: 1260, now: now, dismissed: dismissed);

  test('starts at 8:00 and stays until touched', () {
    expect(on(DateTime(2026, 11, 10, 7, 59)), true); // yesterday's start, never touched
    expect(on(DateTime(2026, 11, 10, 7, 59), dismissed: DateTime(2026, 11, 9, 22)), false);
    expect(on(DateTime(2026, 11, 10, 8, 0), dismissed: DateTime(2026, 11, 9, 22)), true);
    expect(on(DateTime(2026, 11, 10, 9, 0), dismissed: DateTime(2026, 11, 10, 8, 30)), false);
  });

  test('with an end time it stops by itself', () {
    expect(on(DateTime(2026, 11, 10, 12), endOn: true), true);
    expect(on(DateTime(2026, 11, 10, 21, 0), endOn: true), false);
    expect(on(DateTime(2026, 11, 10, 7, 0), endOn: true), false);
  });

  test('off when not scheduled', () {
    expect(screenSaverScheduled(on: false, from: 480, endOn: false, to: 0, now: DateTime(2026, 11, 10, 9)), false);
  });
}
