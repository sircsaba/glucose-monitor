import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/logic/bolus_calc.dart';

void main() {
  test('carbs + correction - IOB, rounded down to 0.05', () {
    final c = BolusCalc(carbs: 30, bgMg: 180, icr: 10, isf: 40, targetMg: 100, iob: 0.5);
    expect(c.carbDose, closeTo(3.0, 1e-9));
    expect(c.correction, closeTo(2.0, 1e-9));
    expect(c.total, closeTo(4.5, 1e-9));
  });

  test('never below zero; negative IOB not added', () {
    final c = BolusCalc(carbs: 0, bgMg: 80, icr: 10, isf: 40, targetMg: 100, iob: -0.3);
    expect(c.iobUsed, 0);
    expect(c.total, 0);
  });

  test('switches turn parts off', () {
    final c = BolusCalc(carbs: 20, bgMg: 200, icr: 10, isf: 50, targetMg: 100, iob: 1, useCorrection: false, useIob: false);
    expect(c.total, closeTo(2.0, 1e-9));
  });

  test('no glucose: carbs only', () {
    final c = BolusCalc(carbs: 15, icr: 12, isf: 50, targetMg: 100, iob: 0);
    expect(c.canCorrect, false);
    expect(c.total, closeTo(1.25, 1e-9));
  });
}
