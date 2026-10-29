import 'dart:convert';

/// Gluten verdict for a food.
enum Gluten { free, contains, unsure, unknown }

const mealTypes = ['breakfast', 'lunch', 'supper', 'snack'];
const mealLabels = {'breakfast': 'Breakfast', 'lunch': 'Lunch', 'supper': 'Supper', 'snack': 'Snack'};

/// Nutrients kept for a food, in label order: g, kcal or mg (see [nutrientUnit]).
const nutrientKeys = [
  'energy', 'fat', 'satFat', 'transFat', 'cholesterol', 'sodium', 'carbs', 'fiber', 'sugars', 'protein',
  'potassium', 'calcium', 'iron',
];
const nutrientUnit = {
  'energy': 'kcal', 'cholesterol': 'mg', 'sodium': 'mg', 'potassium': 'mg', 'calcium': 'mg', 'iron': 'mg',
};

/// Nutrition of one portion (or of 100 g in [Food.per100]).
class Nutrition {
  final Map<String, double> v;
  const Nutrition._(this.v);

  Nutrition({
    double? carbs, double? energy, double? protein, double? fat, double? fiber, double? sugars, double? sodium,
    double? satFat, double? transFat, double? cholesterol, double? potassium, double? calcium, double? iron,
  }) : v = {
          if (carbs != null) 'carbs': carbs,
          if (energy != null) 'energy': energy,
          if (protein != null) 'protein': protein,
          if (fat != null) 'fat': fat,
          if (fiber != null) 'fiber': fiber,
          if (sugars != null) 'sugars': sugars,
          if (sodium != null) 'sodium': sodium,
          if (satFat != null) 'satFat': satFat,
          if (transFat != null) 'transFat': transFat,
          if (cholesterol != null) 'cholesterol': cholesterol,
          if (potassium != null) 'potassium': potassium,
          if (calcium != null) 'calcium': calcium,
          if (iron != null) 'iron': iron,
        };

  static const empty = Nutrition._({});

  double? operator [](String k) => v[k];
  double? get carbs => v['carbs'];
  double? get energy => v['energy'];
  double? get protein => v['protein'];
  double? get fat => v['fat'];
  double? get fiber => v['fiber'];
  double? get sugars => v['sugars'];
  double? get sodium => v['sodium'];
  bool get isEmpty => v.isEmpty;

  Nutrition operator +(Nutrition o) {
    final m = Map<String, double>.from(v);
    o.v.forEach((k, x) => m[k] = (m[k] ?? 0) + x);
    return Nutrition._(m);
  }

  Nutrition times(double k) => Nutrition._({for (final e in v.entries) e.key: e.value * k});

  /// Same values with one nutrient changed (null removes it).
  Nutrition withValue(String k, double? x) {
    final m = Map<String, double>.from(v);
    x == null ? m.remove(k) : m[k] = x;
    return Nutrition._(m);
  }

  Map<String, dynamic> toJson() => {for (final k in nutrientKeys) if (v[k] != null) k: _r(v[k]!)};

  factory Nutrition.fromJson(Map<String, dynamic>? j) {
    if (j == null) return empty;
    final m = <String, double>{};
    for (final k in nutrientKeys) {
      final x = num_(j[k]);
      if (x != null) m[k] = x;
    }
    return Nutrition._(m);
  }

  static double _r(double v) => (v * 100).round() / 100;
}

double? num_(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.replaceAll(',', '.'));
  return null;
}

/// A food in the Nightscout food list (api/v1/food), with extra fields.
/// Nightscout's own fields stay as Nightscout's food editor writes them:
/// name, category, subcategory, portion, unit, carbs, fat, protein, energy, gi
/// (all per portion), so foods made in either place show in both.
class Food {
  String? id;
  String name;
  String brand;
  String category;
  double portion; // size of one portion, in [unit]
  String unit; // g, ml, piece, cup, slice...
  String portionText; // as written on the package, e.g. "2 slices (56 g)"
  Nutrition n; // per portion
  Nutrition per100; // per 100 g / ml, when known (barcodes)
  String barcode;
  Gluten gluten;
  List<String> glutenWhy;
  String ingredients;
  String allergens;
  List<String> meals; // breakfast, lunch, supper, snack
  bool favorite;
  String source; // barcode, manual, recipe
  String notes;
  Map<String, dynamic>? recipe; // stage 2: servings, ingredients, steps
  int? gi;
  Map<String, dynamic> _other; // fields we don't use, kept when saving

  Food({
    this.id,
    required this.name,
    this.brand = '',
    this.category = '',
    this.portion = 100,
    this.unit = 'g',
    this.portionText = '',
    this.n = Nutrition.empty,
    this.per100 = Nutrition.empty,
    this.barcode = '',
    this.gluten = Gluten.unknown,
    List<String>? glutenWhy,
    this.ingredients = '',
    this.allergens = '',
    List<String>? meals,
    this.favorite = false,
    this.source = 'manual',
    this.notes = '',
    this.recipe,
    this.gi,
    Map<String, dynamic>? other,
  })  : glutenWhy = glutenWhy ?? [],
        meals = meals ?? [],
        _other = other ?? {};

  double get carbs => n.carbs ?? 0;

  /// Nutrition for [amount] in [unit] (portion size scaled).
  Nutrition forAmount(double amount) => portion <= 0 ? n : n.times(amount / portion);

  /// Same food with a new portion size: values follow the per-100 data when
  /// known, otherwise scaled from the current portion.
  void setPortion(double size) {
    if (size <= 0) return;
    if ((unit == 'g' || unit == 'ml') && per100.carbs != null) {
      n = per100.times(size / 100);
    } else if (portion > 0) {
      n = n.times(size / portion);
    }
    portion = size;
  }

  static const _known = {
    '_id', 'type', 'name', 'brand', 'category', 'portion', 'unit', 'portionText', ...nutrientKeys, 'per100', 'barcode', 'gluten', 'glutenWhy', 'ingredients',
    'allergens', 'meals', 'favorite', 'source', 'notes', 'recipe', 'gi',
  };

  factory Food.fromJson(Map<String, dynamic> j) {
    final other = <String, dynamic>{};
    j.forEach((k, v) {
      if (!_known.contains(k)) other[k] = v;
    });
    return Food(
      id: j['_id']?.toString(),
      name: (j['name'] ?? '').toString(),
      brand: (j['brand'] ?? '').toString(),
      category: (j['category'] ?? '').toString(),
      portion: num_(j['portion']) ?? 100,
      unit: (j['unit'] ?? 'g').toString(),
      portionText: (j['portionText'] ?? '').toString(),
      n: Nutrition.fromJson(j),
      per100: Nutrition.fromJson(j['per100'] is Map ? Map<String, dynamic>.from(j['per100']) : null),
      barcode: (j['barcode'] ?? '').toString(),
      gluten: Gluten.values.firstWhere((g) => g.name == j['gluten'], orElse: () => Gluten.unknown),
      glutenWhy: [for (final s in (j['glutenWhy'] is List ? j['glutenWhy'] as List : const [])) s.toString()],
      ingredients: (j['ingredients'] ?? '').toString(),
      allergens: (j['allergens'] ?? '').toString(),
      meals: [for (final s in (j['meals'] is List ? j['meals'] as List : const [])) s.toString()],
      favorite: j['favorite'] == true,
      source: (j['source'] ?? 'manual').toString(),
      notes: (j['notes'] ?? '').toString(),
      recipe: j['recipe'] is Map ? Map<String, dynamic>.from(j['recipe']) : null,
      gi: (num_(j['gi']))?.round(),
      other: other,
    );
  }

  Map<String, dynamic> toJson() => {
        ..._other,
        if (id != null) '_id': id,
        'type': 'food',
        'name': name,
        if (brand.isNotEmpty) 'brand': brand,
        'category': category,
        'subcategory': _other['subcategory'] ?? '',
        'portion': portion,
        'unit': unit,
        if (portionText.isNotEmpty) 'portionText': portionText,
        ...n.toJson(),
        'carbs': ((n.carbs ?? 0) * 10).round() / 10, // Nightscout's food editor expects a number
        if (per100.carbs != null || per100.energy != null) 'per100': per100.toJson(),
        if (barcode.isNotEmpty) 'barcode': barcode,
        'gluten': gluten.name,
        if (glutenWhy.isNotEmpty) 'glutenWhy': glutenWhy,
        if (ingredients.isNotEmpty) 'ingredients': ingredients,
        if (allergens.isNotEmpty) 'allergens': allergens,
        'meals': meals,
        'favorite': favorite,
        'source': source,
        if (notes.isNotEmpty) 'notes': notes,
        if (recipe != null) 'recipe': recipe,
        if (gi != null) 'gi': gi,
      };

  Food copy() => Food.fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);

  /// Matches a search: name, brand, category, barcode.
  bool matches(String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return true;
    return '$name $brand $category $barcode'.toLowerCase().contains(s);
  }
}

// ------------------------------------------------------------------ gluten

/// Words that mean gluten (English and French, as on Canadian packages).
const _glutenWords = [
  'wheat', 'blé', 'barley', 'orge', 'rye', 'seigle', 'spelt', 'épeautre', 'epeautre', 'kamut', 'triticale',
  'malt', 'semolina', 'semoule', 'durum', 'farro', 'bulgur', 'couscous', 'einkorn', 'emmer', 'graham',
  "brewer's yeast", 'levure de bière', 'seitan', 'gluten',
];

/// Oats are only safe when labelled gluten-free (cross-contact).
const _oatWords = ['oat', 'avoine'];

class GlutenResult {
  final Gluten verdict;
  final List<String> why;
  const GlutenResult(this.verdict, this.why);
}

/// Decides from Open Food Facts data: green only when labelled gluten-free and
/// no gluten ingredient is listed; red when gluten is in the ingredients or the
/// allergens; yellow ("check the package") for "may contain", oats without a
/// gluten-free label, or missing data.
GlutenResult glutenVerdict({
  required List<String> labels,
  required List<String> allergens,
  required List<String> traces,
  required String ingredients,
}) {
  final why = <String>[];
  bool has(List<String> tags, String t) => tags.any((x) => x.toLowerCase().endsWith(':$t') || x.toLowerCase() == t);
  final labelledFree = has(labels, 'gluten-free') || has(labels, 'no-gluten') || has(labels, 'sans-gluten') ||
      labels.any((l) => l.toLowerCase().contains('gluten-free') || l.toLowerCase().contains('sans-gluten'));
  final ing = ' ${ingredients.toLowerCase()} ';
  // "gluten-free oats", "sans gluten" in the ingredients don't count as gluten.
  final cleaned = ing
      .replaceAll('gluten-free', '')
      .replaceAll('gluten free', '')
      .replaceAll('sans gluten', '')
      .replaceAll('without gluten', '')
      .replaceAll('buckwheat', '') // sarrasin is not wheat
      .replaceAll('sarrasin', '')
      .replaceAll('maltodextrin', '') // usually from corn, gluten-free
      .replaceAll('maltodextrine', '')
      .replaceAll('maltitol', '');
  final found = <String>{};
  for (final w in _glutenWords) {
    // Whole words only ("rye" not in "Pryer"), plural allowed ("oats", "malts").
    if (RegExp('(^|[^a-zà-ÿ])${RegExp.escape(w)}s?(\$|[^a-zà-ÿ])').hasMatch(cleaned)) found.add(w);
  }
  if (has(allergens, 'gluten')) {
    why.add('Gluten is listed in the allergens');
  }
  if (found.isNotEmpty) why.add('Ingredients: ${found.join(', ')}');
  if (why.isNotEmpty) return GlutenResult(Gluten.contains, why);

  final mayContain = has(traces, 'gluten');
  final oats = _oatWords.any((w) => RegExp('(^|[^a-zà-ÿ])${w}s?(\$|[^a-zà-ÿ])').hasMatch(cleaned));
  if (labelledFree && !mayContain) {
    return GlutenResult(Gluten.free, ['Labelled gluten-free, no gluten ingredient listed']);
  }
  if (mayContain) why.add('May contain gluten (traces)');
  if (oats && !labelledFree) why.add('Contains oats without a gluten-free label');
  if (ingredients.trim().isEmpty) why.add('No ingredient list in the database');
  if (why.isEmpty) why.add('No gluten ingredient listed, but not labelled gluten-free');
  return GlutenResult(Gluten.unsure, why);
}

// ------------------------------------------------------------- Open Food Facts

/// A Food from an Open Food Facts product (api/v2/product/<barcode>), or null.
Food? foodFromOff(Map<String, dynamic> j, String barcode) {
  if (j['status'] != 1 && j['status'] != '1' || j['product'] is! Map) return null;
  final p = Map<String, dynamic>.from(j['product'] as Map);
  final nm = p['nutriments'] is Map ? Map<String, dynamic>.from(p['nutriments'] as Map) : <String, dynamic>{};
  List<String> tags(String k) => [for (final t in (p[k] is List ? p[k] as List : const [])) t.toString()];

  String pick(List<String> keys) {
    for (final k in keys) {
      final v = (p[k] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  final name = pick(['product_name_en', 'product_name', 'product_name_fr', 'generic_name']);
  final ingredients = pick(['ingredients_text_en', 'ingredients_text', 'ingredients_text_fr']);
  double? kcal100 = num_(nm['energy-kcal_100g']);
  final kj100 = num_(nm['energy-kj_100g'] ?? nm['energy_100g']);
  if (kcal100 == null && kj100 != null) kcal100 = kj100 / 4.184;
  double? mg(String k) {
    final x = num_(nm[k]);
    return x == null ? null : x * 1000; // Open Food Facts keeps these in g
  }

  final per100 = Nutrition(
    carbs: num_(nm['carbohydrates_100g']),
    energy: kcal100,
    protein: num_(nm['proteins_100g']),
    fat: num_(nm['fat_100g']),
    fiber: num_(nm['fiber_100g']),
    sugars: num_(nm['sugars_100g']),
    sodium: mg('sodium_100g'),
    satFat: num_(nm['saturated-fat_100g']),
    transFat: num_(nm['trans-fat_100g']),
    cholesterol: mg('cholesterol_100g'),
    potassium: mg('potassium_100g'),
    calcium: mg('calcium_100g'),
    iron: mg('iron_100g'),
  );
  final serving = num_(p['serving_quantity']);
  final servingUnit = (p['serving_quantity_unit'] ?? '').toString().toLowerCase();
  final unit = servingUnit == 'ml' || (p['quantity'] ?? '').toString().toLowerCase().contains('ml') ? 'ml' : 'g';
  final portion = serving != null && serving > 0 ? serving : 100.0;
  final g = glutenVerdict(
    labels: tags('labels_tags'),
    allergens: tags('allergens_tags'),
    traces: tags('traces_tags'),
    ingredients: ingredients,
  );
  final cats = tags('categories_tags');
  return Food(
    name: name.isEmpty ? 'Product $barcode' : name,
    brand: (p['brands'] ?? '').toString().split(',').first.trim(),
    category: cats.isEmpty ? '' : _tagText(cats.last),
    portion: portion,
    unit: unit,
    portionText: (p['serving_size'] ?? '').toString(),
    per100: per100,
    n: per100.times(portion / 100),
    barcode: barcode,
    gluten: g.verdict,
    glutenWhy: g.why,
    ingredients: ingredients,
    allergens: [...tags('allergens_tags').map(_tagText), ...tags('traces_tags').map((t) => 'may contain ${_tagText(t)}')]
        .join(', '),
    source: 'barcode',
  );
}

String _tagText(String t) {
  final s = t.contains(':') ? t.substring(t.indexOf(':') + 1) : t;
  final w = s.replaceAll('-', ' ');
  return w.isEmpty ? w : w[0].toUpperCase() + w.substring(1);
}

// ------------------------------------------------------------------ a meal

/// One food in a meal, with how much of it.
class MealItem {
  final Food food;
  double amount; // in food.unit
  MealItem(this.food, this.amount);
  Nutrition get n => food.forAmount(amount);
}

class Meal {
  final List<MealItem> items = [];
  Nutrition get total => items.fold(Nutrition.empty, (a, i) => a + i.n);
  double get carbs => total.carbs ?? 0;
  bool get isEmpty => items.isEmpty;

  /// Worst gluten verdict in the meal.
  Gluten get gluten {
    if (items.any((i) => i.food.gluten == Gluten.contains)) return Gluten.contains;
    if (items.any((i) => i.food.gluten == Gluten.unsure || i.food.gluten == Gluten.unknown)) return Gluten.unsure;
    return items.isEmpty ? Gluten.unknown : Gluten.free;
  }

  /// "Scrambled eggs 2 pieces, Bacon 30 g, Dragon fruit 100 g"
  String describe() => items.map((i) => '${i.food.name} ${fmtAmount(i.amount)} ${unitFor(i.amount, i.food.unit)}').join(', ');

  /// Kept on the treatment so meals can be analysed later.
  List<Map<String, dynamic>> toFoodsJson() => [
        for (final i in items)
          {
            if (i.food.id != null) 'foodId': i.food.id,
            'name': i.food.name,
            'amount': i.amount,
            'unit': i.food.unit,
            ...i.n.toJson(),
          }
      ];
}

/// "2 pieces", "1 slice", "30 g".
String unitFor(double amount, String unit) =>
    const {'piece', 'slice', 'cup', 'serving'}.contains(unit) && amount != 1 ? '${unit}s' : unit;

String fmtAmount(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
