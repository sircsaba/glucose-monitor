import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/logic/barcode.dart';
import 'package:glucose_monitor/logic/food.dart';
import 'package:glucose_monitor/logic/recipe_ai.dart';
import 'package:image/image.dart' as img;
import 'package:zxing_lib/zxing.dart';

GlutenResult v({List<String> labels = const [], List<String> allergens = const [], List<String> traces = const [], String ing = ''}) =>
    glutenVerdict(labels: labels, allergens: allergens, traces: traces, ingredients: ing);

void main() {
  group('gluten', () {
    test('labelled gluten-free with clean ingredients is green', () {
      expect(v(labels: ['en:gluten-free'], ing: 'rice flour, sugar, salt').verdict, Gluten.free);
    });
    test('wheat in the ingredients is red, even with a label', () {
      expect(v(labels: ['en:gluten-free'], ing: 'Wheat flour, water').verdict, Gluten.contains);
    });
    test('gluten in the allergens is red', () {
      expect(v(allergens: ['en:gluten'], ing: 'flour').verdict, Gluten.contains);
    });
    test('French ingredients: blé and orge', () {
      expect(v(ing: 'farine de blé enrichie').verdict, Gluten.contains);
      expect(v(ing: "malt d'orge").verdict, Gluten.contains);
    });
    test('no false alarms: vegetable, buckwheat, maltodextrin, gluten-free oats', () {
      expect(v(labels: ['en:gluten-free'], ing: 'vegetable oil, buckwheat, maltodextrin').verdict, Gluten.free);
      expect(v(labels: ['en:gluten-free'], ing: 'gluten-free oats').verdict, Gluten.free);
    });
    test('may contain is yellow', () {
      expect(v(labels: ['en:gluten-free'], traces: ['en:gluten'], ing: 'corn').verdict, Gluten.unsure);
    });
    test('oats without a label are yellow', () {
      final r = v(ing: 'whole grain oats, sugar');
      expect(r.verdict, Gluten.unsure);
      expect(r.why.join(), contains('oats'));
    });
    test('no ingredient list is yellow', () {
      expect(v().verdict, Gluten.unsure);
    });
    test('clean ingredients without a label are yellow', () {
      expect(v(ing: 'potatoes, sunflower oil, salt').verdict, Gluten.unsure);
    });
  });

  group('Open Food Facts', () {
    final off = {
      'status': 1,
      'product': {
        'product_name': 'Corn tortilla chips',
        'brands': 'Acme, Acme Foods',
        'serving_size': '28 g',
        'serving_quantity': 28,
        'categories_tags': ['en:snacks', 'en:tortilla-chips'],
        'labels_tags': ['en:gluten-free'],
        'allergens_tags': [],
        'traces_tags': [],
        'ingredients_text': 'Corn, vegetable oil, salt',
        'nutriments': {
          'carbohydrates_100g': 64,
          'energy-kcal_100g': 500,
          'proteins_100g': 7,
          'fat_100g': 25,
          'fiber_100g': 5,
          'sugars_100g': 1,
          'sodium_100g': 0.4,
        },
      },
    };
    test('reads name, portion and nutrition per portion', () {
      final f = foodFromOff(off, '0123456789012')!;
      expect(f.name, 'Corn tortilla chips');
      expect(f.brand, 'Acme');
      expect(f.portion, 28);
      expect(f.carbs, closeTo(17.92, 0.01));
      expect(f.n.energy, closeTo(140, 0.01));
      expect(f.n.sodium, closeTo(112, 0.01));
      expect(f.gluten, Gluten.free);
      expect(f.category, 'Tortilla chips');
    });
    test('changing the portion follows the per-100 g values', () {
      final f = foodFromOff(off, '0123456789012')!;
      f.setPortion(50);
      expect(f.carbs, closeTo(32, 0.01));
    });
    test('unknown product', () {
      expect(foodFromOff({'status': 0}, '1'), isNull);
    });
  });

  group('food and meal', () {
    test('keeps Nightscout fields and unknown fields when saved again', () {
      final f = Food.fromJson({'_id': 'a1', 'name': 'Toast', 'portion': 1, 'unit': 'slice', 'carbs': 15, 'subcategory': 'Bread', 'gi': 2, 'x': 7});
      final j = f.toJson();
      expect(j['_id'], 'a1');
      expect(j['type'], 'food');
      expect(j['carbs'], 15);
      expect(j['subcategory'], 'Bread');
      expect(j['gi'], 2);
      expect(j['x'], 7);
    });
    test('meal totals and worst gluten', () {
      final eggs = Food(name: 'Scrambled eggs', portion: 2, unit: 'piece', n: const Nutrition(carbs: 1, energy: 180), gluten: Gluten.free);
      final bacon = Food(name: 'Bacon', portion: 30, unit: 'g', n: const Nutrition(carbs: 0.4, energy: 160), gluten: Gluten.free);
      final fruit = Food(name: 'Dragon fruit', portion: 100, unit: 'g', n: const Nutrition(carbs: 13, energy: 60), gluten: Gluten.unsure);
      final m = Meal()
        ..items.add(MealItem(eggs, 2))
        ..items.add(MealItem(bacon, 60))
        ..items.add(MealItem(fruit, 150));
      expect(m.carbs, closeTo(1 + 0.8 + 19.5, 0.001));
      expect(m.total.energy, closeTo(180 + 320 + 90, 0.001));
      expect(m.gluten, Gluten.unsure);
      expect(m.describe(), 'Scrambled eggs 2 piece, Bacon 60 g, Dragon fruit 150 g');
      expect(m.toFoodsJson().length, 3);
    });
  });

  group('barcode', () {
    test('normalize', () {
      expect(normalizeBarcode('0 55000 12345 6'), '0055000123456');
      expect(normalizeBarcode('5901234123457'), '5901234123457');
    });
    test('reads an EAN-13 from an image', () {
      final m = MultiFormatWriter().encode('5901234123457', BarcodeFormat.ean13, 400, 160);
      final im = img.Image(width: m.width + 40, height: m.height + 40);
      img.fill(im, color: img.ColorRgb8(255, 255, 255));
      for (var y = 0; y < m.height; y++) {
        for (var x = 0; x < m.width; x++) {
          if (m.get(x, y)) im.setPixelRgb(x + 20, y + 20, 0, 0, 0);
        }
      }
      expect(readBarcodeImage(im), '5901234123457');
      expect(readBarcode(img.encodePng(im)), '5901234123457');
    });
    test('reads a UPC-A as 13 digits', () {
      final m = MultiFormatWriter().encode('036000291452', BarcodeFormat.upcA, 400, 160);
      final im = img.Image(width: m.width + 40, height: m.height + 40);
      img.fill(im, color: img.ColorRgb8(255, 255, 255));
      for (var y = 0; y < m.height; y++) {
        for (var x = 0; x < m.width; x++) {
          if (m.get(x, y)) im.setPixelRgb(x + 20, y + 20, 0, 0, 0);
        }
      }
      expect(readBarcodeImage(im), '0036000291452');
    });
  });

  group('recipe', () {
    test('reads the AI answer into a food with its recipe', () {
      final f = recipeFromJson({
        'name': 'Banana muffins',
        'servings': 12,
        'servingText': '1 muffin',
        'servingGrams': 60,
        'ingredients': [
          {'name': 'rice flour blend, gluten-free', 'amount': '2 cups', 'carbs': 160, 'gluten': 'free'},
          {'name': 'baking powder', 'amount': '2 tsp', 'carbs': 2, 'gluten': 'unsure'},
          {'name': 'bananas', 'amount': '3', 'carbs': 81, 'gluten': 'free'},
        ],
        'perServing': {'carbs': 25, 'energy': 180, 'protein': 3, 'fat': 7},
        'steps': ['Heat the oven to 180 °C.', 'Mix.', 'Bake 20 minutes.'],
        'gluten': 'unsure',
        'glutenWhy': [],
        'meals': ['breakfast', 'snack', 'dessert'],
        'cookMinutes': 20,
      });
      expect(f.name, 'Banana muffins');
      expect(f.source, 'recipe');
      expect(f.portion, 60);
      expect(f.unit, 'g');
      expect(f.carbs, 25);
      expect(f.per100.carbs, closeTo(41.67, 0.01));
      expect(f.gluten, Gluten.unsure);
      expect(f.glutenWhy.single, contains('baking powder'));
      expect(f.meals, ['breakfast', 'snack']);
      expect((f.recipe!['steps'] as List).length, 3);
      expect(f.recipe!['servings'], 12);
      expect(f.ingredients, contains('2 cups rice flour blend'));
    });
  });
}
