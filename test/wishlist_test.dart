import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/data/nightscout.dart';
import 'package:glucose_monitor/logic/food.dart';
import 'package:glucose_monitor/logic/insulin_safety.dart';
import 'package:glucose_monitor/logic/school_lunch.dart';

void main() {
  group('absorption of a meal', () {
    test('each food its own time, weighted by carbs; fat and protein add time', () {
      final juice = Food(name: 'Juice', portion: 1, unit: 'serving', n: Nutrition(carbs: 30), absorption: 2);
      final pizza = Food(name: 'Pizza', portion: 1, unit: 'piece', n: Nutrition(carbs: 30, fat: 20, protein: 15), absorption: 4);
      final m = Meal()
        ..items.add(MealItem(juice, 1))
        ..items.add(MealItem(pizza, 1));
      final (h, why) = m.absorption();
      // (2 + 4) / 2 = 3 h, + 35 g fat/protein -> +0.5 h
      expect(h, 3.5);
      expect(why, contains('fat and protein'));
    });
    test('GI when no time is set: 1 low = slow, 3 high = fast', () {
      expect(Food(name: 'a', gi: 1).absorptionHours(), 4);
      expect(Food(name: 'b', gi: 3).absorptionHours(), 2);
      expect(Food(name: 'c').absorptionHours(), 3);
    });
    test('absorption is kept when saved', () {
      final f = Food.fromJson(Food(name: 'Rice', absorption: 2.5).toJson());
      expect(f.absorption, 2.5);
    });
  });

  group('insulin safety', () {
    final now = DateTime(2026, 11, 3, 12);
    Entry at(double mg, {String dir = 'Flat', int ago = 2}) => Entry(now.subtract(Duration(minutes: ago)), mg, dir);
    InsulinSafety check(Entry? e, {List<double>? pred}) {
      final d = DeviceInfo();
      if (pred != null) d.predLines.add(pred);
      return insulinSafety(latest: e, device: d, lowMg: 72, cautionMg: 90, mmol: true, now: now);
    }

    test('below the low limit: refused', () {
      expect(check(at(65)).block, isNotNull);
    });
    test('under the caution level, falling fast, predicted low: warnings', () {
      expect(check(at(85)).warnings.single, contains('under'));
      expect(check(at(150, dir: 'DoubleDown')).warnings.single, contains('falling fast'));
      expect(check(at(120), pred: [120, 110, 90, 70, 60]).warnings.single, contains('Loop predicts'));
    });
    test('fine', () {
      expect(check(at(140)).ok, isTrue);
    });
    test('old or no reading: a warning, never a block', () {
      expect(check(at(60, ago: 40)).block, isNull);
      expect(check(at(60, ago: 40)).warnings.first, contains('minutes old'));
      expect(check(null).warnings, isNotEmpty);
    });
  });

  group('default school lunch', () {
    test('a school day starts from the default box; the default stays as it is', () {
      final def = SchoolLunch(SchoolLunch.defaultKey)..add(Food(id: 'a', name: 'Apple', portion: 1, unit: 'piece', n: Nutrition(carbs: 25)), 1);
      expect(def.isDefault, isTrue);
      final day = def.copyFor('2026-11-04');
      expect(day.date, '2026-11-04');
      expect(day.items.single.food.name, 'Apple');
      day.markEaten({day.items.single.key: 1}, how: 'loop');
      expect(day.items.single.done, isTrue);
      expect(def.items.single.done, isFalse);
      final back = SchoolLunch.fromJson(Map<String, dynamic>.from(def.toJson()))!;
      expect(back.isDefault, isTrue);
      expect(back.isPast, isFalse);
    });
  });
}
