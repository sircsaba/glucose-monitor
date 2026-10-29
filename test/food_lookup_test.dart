import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/logic/cnf.dart';
import 'package:glucose_monitor/logic/food.dart';
import 'package:glucose_monitor/logic/food_lookup.dart';
import 'package:glucose_monitor/ui/food_edit_screen.dart';

void main() {
  final cnf = Cnf.parse(File('assets/cnf.json').readAsStringSync());

  void show(String q) {
    // ignore: avoid_print
    print('$q -> ${lookupGeneric(cnf, q, limit: 5).map((f) => '${f.id} ${f.en}').join(' | ')}');
  }

  test('what people type finds the right generic food', () {
    for (final q in ['bbq chicken', 'chicken breast', 'poulet bbq', 'banana', 'white rice', 'apple', 'french fries', 'milk 2%', 'pain blanc']) {
      show(q);
    }
    expect(cnfQuery('BBQ chicken'), 'roasted chicken');
    expect(lookupGeneric(cnf, 'apple').first.en, startsWith('Apple, raw'));
    expect(lookupGeneric(cnf, 'chicken breast').first.id, 842);
    expect(lookupGeneric(cnf, 'banana').first.id, 1704);
    expect(lookupGeneric(cnf, 'french fries').first.en, contains('french-fried'));
    final top = cnf.search(cnfQuery('bbq chicken breast'), limit: 5).map((f) => f.id);
    expect(top, contains(842)); // Chicken, broiler, breast, meat, roasted
    expect(cnf.search('banana').first.en.toLowerCase(), contains('banana'));
  });

  test('portions: pieces first, 100 g last', () {
    final p = cnfPortions(cnf.byId[842]!);
    expect(p.first.label, '1 breast');
    expect(p.first.grams, 172);
    expect(p.last.label, '100 g');
  });

  test('food from the nutrient file', () {
    final f = foodFromCnf(cnf.byId[842]!, const CnfPortion('1 breast', 172), category: 'Poultry Products');
    expect(f.carbs, 0);
    expect(f.n.protein, closeTo(31.02 * 1.72, 0.01));
    expect(f.n['iron'], isNotNull);
    expect(f.n['calcium'], isNotNull);
    expect(f.portionText, '1 breast (172 g)');
    expect(f.gluten, Gluten.free);
    expect(f.per100.carbs, 0);
  });

  test('gluten of generic foods', () {
    expect(cnfGluten('Chicken, broiler, breast, meat, roasted'), Gluten.free);
    expect(cnfGluten('Chicken, breaded, fried'), Gluten.contains);
    expect(cnfGluten('Bread, white, commercial'), Gluten.contains);
    expect(cnfGluten('Rice, white, long-grain, cooked'), Gluten.free);
    expect(cnfGluten('Chicken, wing, frozen, glazed, barbecue flavour'), Gluten.unsure);
    expect(cnfGluten('Banana, raw'), Gluten.free);
  });

  testWidgets('the food form shows every nutrient, iron and calcium too', (t) async {
    t.view.physicalSize = const Size(390, 844) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final f = foodFromCnf(cnf.byId[842]!, const CnfPortion('1 breast', 172));
    await t.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: FoodEditScreen(food: f, isNew: true)));
    await t.pump();
    for (final n in ['Carbs', 'Calories', 'Protein', 'Potassium', 'Calcium', 'Iron']) {
      await t.scrollUntilVisible(find.text(n), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text(n), findsWidgets, reason: n);
    }
  });
}
