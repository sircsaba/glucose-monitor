import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/logic/cnf.dart';
import 'package:glucose_monitor/logic/food.dart';
import 'package:glucose_monitor/logic/recipe_parse.dart';
import 'package:glucose_monitor/ui/nutrition_label.dart';

void main() {
  group('ingredient lines', () {
    void check(String line, double? qty, String? unit, String name) {
      final p = parseIngredient(line);
      expect(p.qty == null ? null : (p.qty! * 1000).round() / 1000, qty == null ? null : (qty * 1000).round() / 1000, reason: line);
      expect(p.unit, unit, reason: line);
      expect(p.name, name, reason: line);
    }

    test('English', () {
      check('2 cups rice flour', 500, 'ml', 'rice flour');
      check('1 1/2 cups milk', 375, 'ml', 'milk');
      check('1½ tsp baking powder', 7.5, 'ml', 'baking powder');
      check('½ cup butter, softened', 125, 'ml', 'butter');
      check('3 ripe bananas, mashed', 3, null, 'ripe bananas');
      check('200 g sugar', 200, 'g', 'sugar');
      check('200g dark chocolate (70%)', 200, 'g', 'dark chocolate');
      check('2 tbsp. maple syrup', 30, 'ml', 'maple syrup');
      check('1 lb ground beef', 453.6, 'g', 'ground beef');
      check('2-3 cloves garlic', 2.5, 'piece:cloves', 'garlic');
      check('1 can (400 ml) coconut milk', 400, 'ml', 'coconut milk');
      check('Salt and pepper to taste', null, null, 'Salt and pepper to taste');
      check('• 2 large eggs', 2, null, 'large eggs');
    });

    test('French', () {
      check('2 tasses de farine de riz', 500, 'ml', 'farine de riz');
      check('2 c. à soupe de sucre', 30, 'ml', 'sucre');
      check('1 c. à thé de bicarbonate de soude', 5, 'ml', 'bicarbonate de soude');
      check('250 ml de lait', 250, 'ml', 'lait');
      check("1,5 tasse d'avoine", 375, 'ml', 'avoine');
      check('3 oeufs', 3, null, 'oeufs');
      check('1 pincée de sel', 0.4, 'g', 'sel');
    });
  });

  test('a recipe with headings', () {
    final r = splitRecipe('''
Banana muffins
Makes 12

Ingredients
2 cups gluten-free flour blend
3 ripe bananas
1/3 cup maple syrup

Directions
1. Heat the oven to 180 °C.
2. Mash the bananas and mix
with the syrup.
3. Bake 20 minutes.
''');
    expect(r.title, 'Banana muffins');
    expect(r.servings, 12);
    expect(r.ingredients, ['2 cups gluten-free flour blend', '3 ripe bananas', '1/3 cup maple syrup']);
    expect(r.steps.length, 3);
    expect(r.steps[1], 'Mash the bananas and mix with the syrup.');
  });

  test('a recipe without headings (French)', () {
    final r = splitRecipe('''
Crêpes
2 tasses de lait
1 tasse de farine de riz
2 oeufs
Mélanger tous les ingrédients dans un grand bol jusqu'à ce que la pâte soit lisse.
Cuire dans une poêle chaude.
''');
    expect(r.title, 'Crêpes');
    expect(r.ingredients.length, 3);
    expect(r.steps.length, 2);
  });

  group('gluten of an ingredient', () {
    test('plain flour, bread and pasta are wheat', () {
      expect(ingredientGluten('all-purpose flour'), Gluten.contains);
      expect(ingredientGluten('farine'), Gluten.contains);
      expect(ingredientGluten('breadcrumbs'), Gluten.contains);
      expect(ingredientGluten('soy sauce'), Gluten.contains);
    });
    test('gluten-free words win, even matched to wheat flour', () {
      expect(ingredientGluten('gluten-free flour blend', matched: 'Grains, wheat flour, white, all purpose'), Gluten.free);
      expect(ingredientGluten('farine sans gluten'), Gluten.free);
      expect(ingredientGluten('tamari'), Gluten.free);
    });
    test('other flours are fine; oats and baking powder need a check', () {
      expect(ingredientGluten('rice flour'), Gluten.free);
      expect(ingredientGluten('almond flour'), Gluten.free);
      expect(ingredientGluten('rolled oats'), Gluten.unsure);
      expect(ingredientGluten('baking powder'), Gluten.unsure);
      expect(ingredientGluten('ripe bananas'), Gluten.free);
    });
  });

  group('Canadian Nutrient File', () {
    final cnf = Cnf.parse(File('assets/cnf.json').readAsStringSync());

    test('loaded', () {
      expect(cnf.foods.length, greaterThan(5000));
    });
    test('common ingredients find the right food first, in English and French', () {
      expect(cnf.search('all-purpose flour').first.id, 501865);
      expect(cnf.search('farine').first.id, 501865);
      expect(cnf.search('rice flour').first.id, 4429);
      expect(cnf.search('farine de riz').first.id, 4429);
      expect(cnf.search('large eggs').first.id, 125);
      expect(cnf.search('oeufs').first.id, 125);
      expect(cnf.search('ripe bananas').first.id, 1704);
      expect(cnf.search('sucre').first.id, 4318);
      expect(cnf.search('brown sugar').first.id, 4317);
    });
    test('almond flour is not wheat flour', () {
      expect(cnf.search('almond flour').first.id, isNot(501865));
    });
    test('grams from cups, spoons and pieces', () {
      final flour = cnf.byId[501865]!;
      final (g, guessed) = gramsFor(parseIngredient('2 cups all-purpose flour'), flour);
      expect(guessed, isTrue);
      expect(g, inInclusiveRange(230, 290)); // about 125 g a cup
      final egg = cnf.byId[125]!;
      final (ge, _) = gramsFor(parseIngredient('3 large eggs'), egg);
      expect(ge, inInclusiveRange(140, 180));
      final banana = cnf.byId[1704]!;
      final (gb, _) = gramsFor(parseIngredient('3 bananas'), banana);
      expect(gb, inInclusiveRange(300, 400));
      final (gs, _) = gramsFor(parseIngredient('200 g sugar'), cnf.byId[4318]);
      expect(gs, 200);
    });
    test('a whole recipe', () {
      final lines = ['2 cups rice flour', '3 ripe bananas', '1/3 cup maple syrup', '2 large eggs', '1 tsp baking soda'];
      var total = Nutrition.empty;
      for (final l in lines) {
        final p = parseIngredient(l);
        final f = cnf.search(p.name).first;
        final (g, _) = gramsFor(p, f);
        total = total + f.per100.times((g ?? 0) / 100);
      }
      // rice flour ~316 g x 80 % + bananas ~350 g x 23 % + syrup ~110 g x 67 %
      expect(total.carbs!, inInclusiveRange(250, 460));
      expect(total.energy!, greaterThan(1000));
    });
  });

  group('nutrition label', () {
    test('rounding like on packages', () {
      expect(NutritionLabel.kcal(183), '180');
      expect(NutritionLabel.kcal(47), '45');
      expect(NutritionLabel.grams(0.3), '0');
      expect(NutritionLabel.grams(2.3), '2.5');
      expect(NutritionLabel.grams(12.6), '13');
      expect(NutritionLabel.mg(212), '210');
      expect(NutritionLabel.mg(72), '70');
      expect(NutritionLabel.pct(7, 75), '9 %');
    });
    for (final us in [false, true]) {
      testWidgets('draws the ${us ? 'US' : 'Canadian'} label', (t) async {
        t.view.physicalSize = const Size(390, 844) * 3;
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: NutritionLabel(
                n: Nutrition(carbs: 25, energy: 183, fat: 7.2, satFat: 1.1, transFat: 0, protein: 3, sodium: 212, fiber: 2, sugars: 11, cholesterol: 31, potassium: 220, calcium: 45, iron: 0.8),
                servingEn: '1 muffin (60 g)',
                servingFr: '1 muffin (60 g)',
                servingsPerContainer: 12,
                us: us,
              ),
            ),
          ),
        ));
        expect(find.textContaining('Nutrition Facts'), findsOneWidget);
        expect(find.text(us ? 'Calories' : 'Valeur nutritive'), findsOneWidget);
      });
    }
  });
}
