import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/logic/food.dart';

void main() {
  tearDown(() => Nutrition.netCarbs = true);

  test('net carbs are carbs minus fibre', () {
    final bread = Food(name: 'Bread', portion: 1, unit: 'slice', n: Nutrition(carbs: 20, fiber: 3));
    expect(bread.carbs, 17);
    final m = Meal()..items.add(MealItem(bread, 2));
    expect(m.carbs, 34);
  });

  test('fibre never takes carbs below zero', () {
    expect(Nutrition(carbs: 2, fiber: 5).counted, 0);
    expect(Nutrition(carbs: 10).counted, 10);
  });

  test('switch off counts total carbs', () {
    Nutrition.netCarbs = false;
    expect(Food(name: 'Bread', portion: 1, unit: 'slice', n: Nutrition(carbs: 20, fiber: 3)).carbs, 20);
  });
}
