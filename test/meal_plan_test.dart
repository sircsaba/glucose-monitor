import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/logic/meal_plan.dart';

void main() {
  final now = DateTime(2026, 10, 29, 11, 0);

  test('all now: one step with the carbs, rounded to 0.05 U', () {
    final s = planAllNow(3.27);
    expect(s.length, 1);
    expect(s.first.units, 3.25);
    expect(s.first.withCarbs, isTrue);
    expect(s.first.isNow, isTrue);
  });

  test('part now, rest later', () {
    final s = planSplit(4.0, 1.5, 15, now);
    expect(s.length, 2);
    expect(s[0].units, 1.5);
    expect(s[0].withCarbs, isTrue);
    expect(s[0].isNow, isTrue);
    expect(s[1].units, 2.5);
    expect(s[1].withCarbs, isFalse);
    expect(s[1].at, DateTime(2026, 10, 29, 11, 15));
  });

  test('prebolus before a meal at a time; all of it = one step', () {
    final meal = DateTime(2026, 10, 29, 12, 0);
    final s = planAtTime(4.0, 2.0, meal, 10);
    expect(s[0].at, DateTime(2026, 10, 29, 11, 50));
    expect(s[1].at, meal);
    expect(planAtTime(4.0, 4.0, meal, 10).length, 1);
  });

  test('when glucose rises above: due only on a new reading at or above the level, or at the end of the wait', () {
    final s = planWhenAbove(3.0, 100, 45, now).first;
    // An old reading (before the plan started) does not count.
    expect(stepDueReason(s, now: now, planStarted: now, latestMg: 150, latestTime: now.subtract(const Duration(minutes: 1))), isNull);
    // Still below.
    expect(stepDueReason(s, now: now.add(const Duration(minutes: 10)), planStarted: now, latestMg: 90, latestTime: now.add(const Duration(minutes: 10))), isNull);
    // Above.
    expect(stepDueReason(s, now: now.add(const Duration(minutes: 15)), planStarted: now, latestMg: 101, latestTime: now.add(const Duration(minutes: 15))),
        contains('above'));
    // Waited long enough.
    expect(stepDueReason(s, now: now.add(const Duration(minutes: 46)), planStarted: now, latestMg: 80, latestTime: now.add(const Duration(minutes: 45))),
        contains('waiting'));
  });

  test('a step is due at its time, not before; done steps never ring', () {
    final s = planSplit(4.0, 2.0, 15, now)[1];
    expect(stepDueReason(s, now: now.add(const Duration(minutes: 14)), planStarted: now), isNull);
    expect(stepDueReason(s, now: now.add(const Duration(minutes: 15)), planStarted: now), isNotNull);
    s.state = MealStepState.done;
    expect(stepDueReason(s, now: now.add(const Duration(minutes: 20)), planStarted: now), isNull);
  });

  test('plan survives saving and loading; next skips finished steps', () {
    final p = MealPlan(started: now, carbs: 45, note: 'Eggs, bacon', steps: planSplit(4.0, 2.0, 15, now));
    p.steps.first.state = MealStepState.done;
    final q = MealPlan.fromJson(p.toJson());
    expect(q.carbs, 45);
    expect(q.note, 'Eggs, bacon');
    expect(q.next!.label, 'Rest of the bolus');
    expect(q.next!.at, p.steps[1].at);
    expect(q.totalUnits, 4.0);
  });
}
