import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/logic/food.dart';
import 'package:glucose_monitor/logic/school_lunch.dart';

void main() {
  final sandwich = Food(id: 's1', name: 'Ham sandwich', portion: 1, unit: 'piece', n: Nutrition(carbs: 34, energy: 310), gluten: Gluten.free);
  final apple = Food(id: 'a1', name: 'Apple', portion: 1, unit: 'piece', n: Nutrition(carbs: 25));

  test('pack, eat part, eat the rest', () {
    final l = SchoolLunch('2026-10-30');
    l.add(sandwich, 1);
    l.add(apple, 1);
    l.add(apple, 1); // the same food twice: one line, 2 apples
    expect(l.items.length, 2);
    expect(l.items[1].amount, 2);

    // Half the sandwich and one apple at noon.
    l.markEaten({'i1': 0.5, 'i2': 1}, how: 'loop', at: DateTime(2026, 10, 30, 12));
    expect(l.items[0].left, 0.5);
    expect(l.items[1].left, 1);
    expect(l.waiting.length, 2);
    expect(l.eaten.length, 2);
    expect(l.eaten.first.carbs, 17);

    // Cannot eat more than what is left.
    l.markEaten({'i1': 3}, how: 'loop');
    expect(l.items[0].done, isTrue);
    expect(l.eaten.last.amount, 0.5);
    expect(l.waiting.map((i) => i.food.name), ['Apple']);
  });

  test('saved and read back like the site keeps it', () {
    final l = SchoolLunch('2026-10-30', id: 'x1');
    l.add(sandwich, 1);
    l.markEaten({'i1': 1}, how: 'logged', at: DateTime(2026, 10, 30, 11, 45));
    final j = l.toJson();
    expect(j['type'], 'schoollunch');
    final back = SchoolLunch.fromJson(Map<String, dynamic>.from(j))!;
    expect(back.id, 'x1');
    expect(back.date, '2026-10-30');
    expect(back.items.single.food.name, 'Ham sandwich');
    expect(back.items.single.done, isTrue);
    expect(back.eaten.single.how, 'logged');
    expect(back.eaten.single.at.hour, 11);
  });

  test('day keys', () {
    expect(SchoolLunch.dayKey(DateTime(2026, 3, 5)), '2026-03-05');
    expect(SchoolLunch('2020-01-01').isPast, isTrue);
  });
}
