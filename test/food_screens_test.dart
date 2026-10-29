import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/logic/food.dart';
import 'package:glucose_monitor/ui/food_edit_screen.dart';
import 'package:glucose_monitor/ui/recipe_builder_screen.dart';
import 'package:glucose_monitor/ui/recipe_screen.dart';

/// The food page and the recipe page draw on a phone and on a tablet without
/// anything overflowing (Flutter reports overflow as a test failure).
void main() {
  final product = foodFromOff({
    'status': 1,
    'product': {
      'product_name': 'Whole grain granola bar with a rather long product name',
      'brands': 'Sample Foods',
      'serving_quantity': 35,
      'serving_size': '1 bar (35 g)',
      'labels_tags': [],
      'allergens_tags': ['en:nuts'],
      'traces_tags': ['en:gluten'],
      'ingredients_text': 'Whole grain oats, honey, almonds, rice crisps (rice flour, sugar, salt)',
      'nutriments': {'carbohydrates_100g': 68, 'energy-kcal_100g': 430, 'fat_100g': 15, 'proteins_100g': 8},
    },
  }, '0000000000031')!;
  final recipe = Food(
    name: 'Banana muffins',
    source: 'recipe',
    portion: 60,
    unit: 'g',
    portionText: '1 muffin (60 g)',
    n: Nutrition(carbs: 25, energy: 180, fat: 7, satFat: 1, protein: 3, sodium: 210, fiber: 2, sugars: 11),
    gluten: Gluten.unsure,
    glutenWhy: ['Check these labels: baking powder'],
    recipe: {
      'servings': 12,
      'servingText': '1 muffin',
      'ingredients': [
        {'name': 'gluten-free flour blend', 'amount': '2 cups gluten-free flour blend', 'grams': 280, 'carbs': 160, 'gluten': 'free'},
        {'name': 'baking powder', 'amount': '2 tsp baking powder', 'grams': 9, 'carbs': 2, 'gluten': 'unsure'},
        {'name': 'ripe bananas', 'amount': '3 ripe bananas', 'grams': 354, 'carbs': 81, 'gluten': 'free'},
      ],
      'steps': ['Heat the oven to 180 °C and line a 12-cup muffin pan with paper cups.', 'Mash the bananas.', 'Bake 20 minutes.'],
      'prepMinutes': 15,
      'cookMinutes': 20,
    },
  );

  for (final size in [const Size(390, 844), const Size(820, 1180)]) {
    testWidgets('food page from a barcode at ${size.width.round()} wide', (t) async {
      t.view.physicalSize = size * 3;
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: FoodEditScreen(food: product, isNew: true, onAddToMeal: (_) {})));
      await t.pump();
      expect(find.text('Check the package'), findsWidgets);
      expect(find.textContaining('May contain gluten'), findsOneWidget);
      await t.drag(find.byType(ListView).first, const Offset(0, -2000));
      await t.pump();
      expect(find.text('Save and add to the meal'), findsOneWidget);
    });

    testWidgets('recipe page and cooking mode at ${size.width.round()} wide', (t) async {
      t.view.physicalSize = size * 3;
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: RecipeScreen(food: recipe)));
      await t.pump();
      expect(find.text('How to make it'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Increase Servings')); // more servings
      await t.pump();
      expect(find.textContaining('All 13'), findsOneWidget);
    });
  }

  testWidgets('recipe builder reads a recipe, matches the ingredients and draws the label', (t) async {
    t.view.physicalSize = const Size(390, 844) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    const text = '''Banana muffins
Makes 12

Ingredients
2 cups rice flour
3 ripe bananas
1/3 cup maple syrup
2 large eggs
1 tsp baking soda
1 cup all-purpose flour

Directions
1. Heat the oven to 180 °C.
2. Mix everything and bake 20 minutes.
''';
    await t.runAsync(() async {
      await t.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: const RecipeBuilderScreen(text: text)));
      // The nutrient file loads in the background.
      for (var i = 0; i < 50 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await t.pump();
      }
    });
    await t.pump();
    expect(find.text('2 cups rice flour'), findsOneWidget);
    expect(find.textContaining('Grains, rice flour, white'), findsOneWidget);
    expect(find.textContaining('Banana, raw'), findsOneWidget);
    expect(find.text('12 servings'), findsOneWidget);
    // The all-purpose flour is wheat: its line has the red Gluten badge.
    await t.scrollUntilVisible(find.text('1 cup all-purpose flour'), 200, scrollable: find.byType(Scrollable).first);
    await t.pump();
    expect(find.text('Gluten'), findsWidgets);
    await t.drag(find.byType(ListView).first, const Offset(0, -3000));
    await t.pump();
    expect(find.text('Valeur nutritive'), findsOneWidget);
    expect(find.text('Save the recipe'), findsOneWidget);
  });
}
