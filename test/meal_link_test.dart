import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/data/nightscout.dart';
import 'package:glucose_monitor/logic/food.dart';
import 'package:glucose_monitor/logic/meal_link.dart';
import 'package:glucose_monitor/logic/nutrition_report.dart';

void main() {
  final t0 = DateTime(2026, 11, 10, 12, 15);
  final carb = Treatment(t: t0, type: 'Carb Correction', carbs: 45, enteredBy: 'Loop');
  final other = Treatment(t: t0.add(const Duration(hours: 6)), type: 'Carb Correction', carbs: 30);

  test('a note at the time of a carb entry says what it was; the newest one counts', () {
    final first = Treatment(t: t0, type: 'Note', mealType: 'lunch', foodType: 'Pizza', describedAt: t0.add(const Duration(hours: 1)));
    final second = Treatment(
      t: t0,
      type: 'Note',
      mealType: 'lunch',
      foodType: 'Pizza and salad',
      describedAt: t0.add(const Duration(hours: 2)),
      foods: const [
        {'name': 'Pizza slice'},
      ],
      nutrition: Nutrition(carbs: 45, energy: 500),
    );
    final all = [carb, other, first, second];
    final links = mealNotes(all);
    expect(links[carb], same(second));
    expect(links[other], isNull);
    expect(mealText(carb, links[carb]), 'Lunch · Pizza and salad · Pizza slice');
    expect(isDescribed(other, null), false);
    // The replaced note is left out (counted once).
    final kept = withoutReplacedNotes(all);
    expect(kept.contains(first), false);
    expect(kept.contains(second), true);
  });

  test('carbs by meal type', () {
    final note = Treatment(t: t0.add(const Duration(minutes: 3)), type: 'Note', mealType: 'lunch');
    final stats = mealTypeStats([carb, other, note]);
    final lunch = stats.firstWhere((m) => m.type == 'lunch');
    final none = stats.firstWhere((m) => m.type == '');
    expect(lunch.count, 1);
    expect(lunch.carbs, 45);
    expect(none.count, 1);
    final r = nutritionReport(from: DateTime(2026, 11, 10), to: DateTime(2026, 11, 10, 23), treatments: [carb, other, note], entries: const []);
    expect(r.byType.length, 2);
  });

  test('meal guessed from the time', () {
    expect(guessMealType(DateTime(2026, 1, 1, 7, 30)), 'breakfast');
    expect(guessMealType(DateTime(2026, 1, 1, 12)), 'lunch');
    expect(guessMealType(DateTime(2026, 1, 1, 18)), 'supper');
    expect(guessMealType(DateTime(2026, 1, 1, 15)), 'snack');
  });
}
