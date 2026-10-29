import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/data/nightscout.dart';
import 'package:glucose_monitor/logic/food.dart';
import 'package:glucose_monitor/logic/nutrition_report.dart';

void main() {
  final day = DateTime(2026, 10, 28);
  DateTime at(int h, [int m = 0, int d = 0]) => DateTime(2026, 10, 28 + d, h, m);

  // Glucose: 100 mg/dL flat, rising to 180 at 9:00 after breakfast, 130 after lunch.
  final entries = <Entry>[];
  for (var t = at(6); t.isBefore(at(23)); t = t.add(const Duration(minutes: 5))) {
    var mg = 100.0;
    final afterBreakfast = t.difference(at(8)).inMinutes;
    if (afterBreakfast > 0 && afterBreakfast <= 120) mg = 100 + 80 * (1 - (afterBreakfast - 60).abs() / 60);
    final afterLunch = t.difference(at(12)).inMinutes;
    if (afterLunch > 0 && afterLunch <= 120) mg = 100 + 30 * (1 - (afterLunch - 60).abs() / 60);
    entries.add(Entry(t, mg, 'Flat'));
  }

  Treatment meal(DateTime t, List<String> foods, double carbs, double kcal, {bool loopCarbsToo = false}) => Treatment(
        t: t,
        type: loopCarbsToo ? 'Note' : 'Meal Bolus',
        carbs: loopCarbsToo ? null : carbs,
        foods: [for (final f in foods) {'name': f}],
        nutrition: Nutrition(carbs: carbs, energy: kcal, protein: 20, fat: 15),
      );

  final treatments = [
    // Monitor Glucose: the meal itself has the carbs.
    meal(at(8), ['Pancakes', 'Maple syrup'], 60, 520),
    // Monitor Glucose Plus: Loop's carb entry + a note with the foods (carbs not counted twice).
    Treatment(t: at(12), type: 'Carb Correction', carbs: 30),
    meal(at(12), ['Rice, cooked', 'Chicken'], 30, 450, loopCarbsToo: true),
    // Snack with Loop only (no foods).
    Treatment(t: at(16), type: 'Carb Correction', carbs: 15),
    // Pancakes again the next day.
    meal(at(8, 0, 1), ['Pancakes'], 45, 400),
  ];

  test('carbs per day from every carb entry, the rest from the meals', () {
    final r = nutritionReport(from: day, to: at(23), treatments: treatments, entries: entries);
    expect(r.days.length, 1);
    final d = r.days.first;
    expect(d.carbs, 60 + 30 + 15);
    expect(d.mealCount, 2);
    expect(d.meals.energy, 520 + 450);
    expect(r.avgMeals.protein, 40);
  });

  test('meals sorted by glucose rise', () {
    final r = nutritionReport(from: day, to: at(23), treatments: treatments, entries: entries);
    expect(r.meals.length, 2);
    expect(r.meals.first.description, 'Pancakes, Maple syrup');
    expect(r.meals.first.startMg, 100);
    expect(r.meals.first.rise, closeTo(80, 0.5));
    expect(r.meals.first.minutesToPeak, 60);
    expect(r.meals.last.rise, closeTo(30, 0.5));
    expect(r.meals.first.overlap, isFalse);
  });

  test('foods by average rise need two meals', () {
    final r = nutritionReport(from: day, to: at(23, 0, 1), treatments: treatments, entries: entries);
    // The second day's pancakes have no readings: no rise, so only one usable meal.
    expect(r.foods, isEmpty);
    final more = [...treatments, meal(at(20), ['Pancakes'], 40, 350)];
    final e2 = [
      ...entries.where((e) => e.t.isBefore(at(20))),
      for (var i = 0; i <= 36; i++) Entry(at(20).add(Duration(minutes: 5 * i)), i <= 12 ? 100 + 5.0 * i : 160, 'Flat'),
    ];
    final r2 = nutritionReport(from: day, to: at(23, 0, 1), treatments: more, entries: e2);
    expect(r2.foods.single.name, 'Pancakes');
    expect(r2.foods.single.meals, 2);
    expect(r2.foods.single.avgRise, closeTo((80 + 60) / 2, 0.5));
  });
}
