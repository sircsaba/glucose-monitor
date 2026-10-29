import 'cnf.dart';
import 'food.dart';

/// One ingredient line of a recipe, read without AI:
/// "1 1/2 cups rice flour", "2 c. à soupe de sucre", "3 bananas, mashed".
class IngredientLine {
  final String raw;
  final double? qty;
  final String? unit; // g, ml, cup, tbsp, tsp, oz, lb, pinch, can, piece (null: a count)
  final String name; // what it is, without amount, unit and notes
  const IngredientLine(this.raw, this.qty, this.unit, this.name);
}

const _fractions = {'½': 0.5, '⅓': 1 / 3, '⅔': 2 / 3, '¼': 0.25, '¾': 0.75, '⅛': 0.125, '⅜': 0.375, '⅝': 0.625, '⅞': 0.875, '⅕': 0.2};

// Unit words (English and French) -> unit and its size in g or ml.
const _units = <String, (String, double)>{
  'kg': ('g', 1000), 'kilo': ('g', 1000), 'kilos': ('g', 1000), 'g': ('g', 1), 'gr': ('g', 1), 'gram': ('g', 1), 'grams': ('g', 1),
  'gramme': ('g', 1), 'grammes': ('g', 1), 'mg': ('g', 0.001),
  'l': ('ml', 1000), 'litre': ('ml', 1000), 'litres': ('ml', 1000), 'liter': ('ml', 1000), 'liters': ('ml', 1000),
  'ml': ('ml', 1), 'millilitre': ('ml', 1), 'millilitres': ('ml', 1), 'cl': ('ml', 10), 'dl': ('ml', 100),
  'cup': ('ml', 250), 'cups': ('ml', 250), 'c': ('ml', 250), 'tasse': ('ml', 250), 'tasses': ('ml', 250),
  'tablespoon': ('ml', 15), 'tablespoons': ('ml', 15), 'tbsp': ('ml', 15), 'tbs': ('ml', 15), 'tbsps': ('ml', 15),
  'teaspoon': ('ml', 5), 'teaspoons': ('ml', 5), 'tsp': ('ml', 5), 'tsps': ('ml', 5),
  'cs': ('ml', 15), 'cc': ('ml', 5), 'cuillere a soupe': ('ml', 15), 'cuilleres a soupe': ('ml', 15), 'c a soupe': ('ml', 15),
  'c a s': ('ml', 15), 'cuillere a the': ('ml', 5), 'cuilleres a the': ('ml', 5), 'c a the': ('ml', 5), 'c a t': ('ml', 5),
  'cuillere a cafe': ('ml', 5), 'cuilleres a cafe': ('ml', 5), 'c a cafe': ('ml', 5),
  'oz': ('g', 28.35), 'ounce': ('g', 28.35), 'ounces': ('g', 28.35), 'fl oz': ('ml', 29.57),
  'lb': ('g', 453.6), 'lbs': ('g', 453.6), 'pound': ('g', 453.6), 'pounds': ('g', 453.6), 'livre': ('g', 453.6), 'livres': ('g', 453.6),
  'pinch': ('g', 0.4), 'pinches': ('g', 0.4), 'pincee': ('g', 0.4), 'pincees': ('g', 0.4), 'dash': ('g', 0.4),
};

String _plain(String s) {
  const from = 'àâäáçéèêëíîïóôöúùûü';
  const to = 'aaaaceeeeiiiooouuuu';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString();
}

/// Reads the amount at the start: "1", "1.5", "1,5", "1 1/2", "1½", "½", "2-3" (middle).
(double?, String) _qty(String s) {
  var t = s.trimLeft();
  for (final e in _fractions.entries) {
    t = t.replaceAllMapped(RegExp('(\\d)${e.key}'), (m) => '${m.group(1)} ${e.key}');
  }
  double? total;
  final num = RegExp(r'^(\d+(?:[.,]\d+)?)(?:\s*[-–à]\s*(\d+(?:[.,]\d+)?))?');
  final frac = RegExp(r'^(\d+)\s*/\s*(\d+)');
  while (true) {
    t = t.trimLeft();
    final f = frac.firstMatch(t);
    if (f != null) {
      total = (total ?? 0) + int.parse(f.group(1)!) / int.parse(f.group(2)!).clamp(1, 1000);
      t = t.substring(f.end);
      continue;
    }
    if (t.isNotEmpty && _fractions.containsKey(t[0])) {
      total = (total ?? 0) + _fractions[t[0]]!;
      t = t.substring(1);
      continue;
    }
    final n = num.firstMatch(t);
    if (n != null && total == null) {
      final a = double.parse(n.group(1)!.replaceAll(',', '.'));
      final b = n.group(2) == null ? null : double.parse(n.group(2)!.replaceAll(',', '.'));
      total = b == null ? a : (a + b) / 2;
      t = t.substring(n.end);
      continue;
    }
    break;
  }
  return (total, t.trimLeft());
}

IngredientLine parseIngredient(String raw) {
  var line = raw.trim().replaceFirst(RegExp(r'^[-•*·▪●○◦]\s*'), '');
  var (qty, rest) = _qty(line);
  // "2 x 400 g" / "1 (400 ml) can"
  rest = rest.replaceFirst(RegExp(r'^[x×]\s*'), '');
  String? unit;
  double size = 1;
  final p = _plain(rest);
  // Longest unit words first ("c. à soupe" before "c").
  final keys = _units.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final k in keys) {
    final pat = RegExp('^${RegExp.escape(k).replaceAll(' ', r'[\s.]*')}\\.?(?=\\s|\$|[^a-z])');
    final m = pat.firstMatch(p.replaceAll('.', ' ').replaceAll(RegExp(r'\s+'), ' '));
    if (m != null && qty != null) {
      unit = _units[k]!.$1;
      size = _units[k]!.$2;
      // Cut the same number of characters from the original text.
      final cut = _cutAfterUnit(rest, k);
      rest = rest.substring(cut);
      break;
    }
  }
  // "can", "boîte", "clove", "gousse", "slice", "tranche" are pieces of something.
  final piece = RegExp(r'^(cans?|bo[iî]tes?|cloves?|gousses?|slices?|tranches?|sticks?|bâtons?|packages?|paquets?)\b', caseSensitive: false).firstMatch(rest);
  if (unit == null && piece != null && qty != null) {
    unit = 'piece:${_plain(piece.group(1)!)}';
    rest = rest.substring(piece.end);
  }
  // "1 can (400 ml) coconut milk", "2 (28 oz) cans tomatoes": the size in brackets.
  final inner = RegExp(r'\((\d+(?:[.,]\d+)?)\s*(ml|g|oz|l)\b', caseSensitive: false).firstMatch(rest);
  if (inner != null && qty != null && (unit == null || unit.startsWith('piece'))) {
    final v = double.parse(inner.group(1)!.replaceAll(',', '.'));
    final u = inner.group(2)!.toLowerCase();
    qty = qty * v * (u == 'oz' ? 28.35 : (u == 'l' ? 1000 : 1));
    unit = u == 'ml' || u == 'l' ? 'ml' : 'g';
    size = 1;
    rest = rest.replaceFirst(RegExp(r'^\s*(cans?|bo[iî]tes?|packages?|paquets?)\b', caseSensitive: false), '');
  }
  var name = rest
      .replaceAll(RegExp(r'\([^)]*\)'), ' ') // notes in brackets
      .replaceFirst(RegExp(r'^\s*(cans?|bo[iî]tes?|packages?|paquets?)\s+', caseSensitive: false), '')
      .replaceFirst(RegExp(r"^\s*(of|de|d'|d’|du|des)\s+", caseSensitive: false), '')
      .replaceFirst(RegExp(r"^\s*(d'|d’)", caseSensitive: false), '');
  // "flour, sifted" -> "flour"; "eggs, beaten" -> "eggs"
  final comma = name.indexOf(',');
  if (comma > 2) name = name.substring(0, comma);
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  return IngredientLine(raw.trim(), qty == null ? null : qty * size, unit, name);
}

int _cutAfterUnit(String rest, String unitKey) {
  // Walk the original text until as many letters as the unit has were passed.
  final letters = unitKey.replaceAll(' ', '').length;
  var seen = 0, i = 0;
  while (i < rest.length && seen < letters) {
    if (RegExp(r'[A-Za-zÀ-ÿ]').hasMatch(rest[i])) seen++;
    i++;
  }
  while (i < rest.length && RegExp(r'[.\s]').hasMatch(rest[i])) {
    i++;
  }
  return i;
}

/// A recipe split into its parts.
class ParsedRecipe {
  final String title;
  final List<String> ingredients;
  final List<String> steps;
  final double? servings;
  const ParsedRecipe(this.title, this.ingredients, this.steps, this.servings);
}

final _ingHead = RegExp(r'^\s*(ingredients?|ingr[ée]dients?)\s*:?\s*$', caseSensitive: false);
final _stepHead = RegExp(
    r'^\s*(directions?|instructions?|method|preparation|pr[ée]paration|steps?|[ée]tapes?|how to make it|mode de pr[ée]paration|r[ée]alisation)\s*:?\s*$',
    caseSensitive: false);
final _servingsRe = RegExp(r'(serves|servings?|yield|makes|portions?|donne|pour)\s*:?\s*(\d+)', caseSensitive: false);

/// Splits recipe text (typed, pasted or read from a photo) into title,
/// ingredient lines and steps. Works with or without "Ingredients" and
/// "Directions" headings.
ParsedRecipe splitRecipe(String text) {
  final lines = text.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  String title = '';
  double? servings;
  final ing = <String>[];
  final steps = <String>[];
  var mode = 0; // 0 unknown, 1 ingredients, 2 steps
  for (final l in lines) {
    final sv = _servingsRe.firstMatch(l);
    if (sv != null && l.length < 40) {
      servings = double.tryParse(sv.group(2)!);
      continue;
    }
    if (_ingHead.hasMatch(l)) {
      mode = 1;
      continue;
    }
    if (_stepHead.hasMatch(l)) {
      mode = 2;
      continue;
    }
    final startsWithAmount = RegExp(r'^[-•*·]?\s*(\d|[½⅓⅔¼¾⅛])').hasMatch(l);
    final numbered = RegExp(r'^(\d{1,2})[.)]\s+\S').hasMatch(l);
    final looksLikeStep = l.length > 60 || numbered || RegExp(r'[.!]$').hasMatch(l) && l.split(' ').length > 6;
    if (mode == 0 && title.isEmpty && !startsWithAmount && l.length < 70) {
      title = l;
      continue;
    }
    if (mode == 2 || (mode == 0 && looksLikeStep && !(startsWithAmount && l.length < 60))) {
      final s = l.replaceFirst(RegExp(r'^(\d{1,2})[.)]\s+'), '');
      // A line that continues the previous step (photo text wraps lines).
      if (steps.isNotEmpty && !numbered && !RegExp(r'[.!:]$').hasMatch(steps.last) && RegExp(r'^[a-zà-ÿ]').hasMatch(s)) {
        steps[steps.length - 1] = '${steps.last} $s';
      } else {
        steps.add(s);
      }
      if (mode == 0) mode = 2;
      continue;
    }
    if (mode == 1 || startsWithAmount || l.length <= 60) {
      ing.add(l);
    } else {
      steps.add(l);
    }
  }
  return ParsedRecipe(title, ing, steps, servings);
}

/// A pasted list of ingredients: one per line (bullets, numbers and headings
/// like "Ingredients" or "For the sauce:" are left out). Lines joined with
/// commas or semicolons on one line ("2 eggs, 1 cup milk") are split too.
List<String> ingredientLines(String text) {
  final out = <String>[];
  for (var l in text.split(RegExp(r'\r?\n'))) {
    l = l.trim().replaceFirst(RegExp(r'^([-•*·▪●◦–]|\d{1,2}[.)])\s+'), '').trim();
    if (l.isEmpty || _ingHead.hasMatch(l) || _stepHead.hasMatch(l)) continue;
    if (RegExp(r'^(for the|pour la|pour le|pour les)\b.*:$', caseSensitive: false).hasMatch(l) || (l.endsWith(':') && l.length < 40)) continue;
    // "2 eggs; 1 cup milk" or "2 eggs, 1 cup milk, 3 bananas": split before each amount.
    final parts = l.split(RegExp(r'\s*[;,]\s*(?=(\d|[½⅓⅔¼¾⅛]))'));
    out.addAll(parts.map((x) => x.trim()).where((x) => x.isNotEmpty));
  }
  return out;
}

// ------------------------------------------------------------- one ingredient

/// An ingredient with its match in the Canadian Nutrient File (or in the
/// user's own foods) and its weight.
class RecipeIngredient {
  String line; // as written
  IngredientLine parsed;
  CnfFood? cnf;
  Food? myFood; // one of the user's foods (e.g. a gluten-free flour blend scanned from its barcode)
  double? grams;
  bool gramsGuessed; // weight worked out from a household measure or a piece
  Gluten gluten;

  RecipeIngredient(this.line, this.parsed, {this.cnf, this.myFood, this.grams, this.gramsGuessed = false, this.gluten = Gluten.unknown});

  String get matchName => myFood?.name ?? cnf?.en ?? '';

  /// Nutrition of this ingredient in the recipe.
  Nutrition get n {
    final g = grams;
    if (g == null) return Nutrition.empty;
    if (myFood != null) {
      final f = myFood!;
      if (f.per100.carbs != null) return f.per100.times(g / 100);
      if ((f.unit == 'g' || f.unit == 'ml') && f.portion > 0) return f.n.times(g / f.portion);
      return f.n.times((parsed.qty ?? 1) / (f.portion <= 0 ? 1 : f.portion));
    }
    return cnf == null ? Nutrition.empty : cnf!.per100.times(g / 100);
  }

  Map<String, dynamic> toJson() => {
        'name': parsed.name.isEmpty ? line : parsed.name,
        'amount': line,
        if (grams != null) 'grams': (grams! * 10).round() / 10,
        if (cnf != null) 'cnf': cnf!.id,
        if (cnf != null) 'match': cnf!.en,
        if (myFood?.id != null) 'foodId': myFood!.id,
        if (myFood != null) 'match': myFood!.name,
        ...n.toJson(),
        'gluten': gluten.name,
      };
}

/// Weight in grams of [p] for [f], from the unit, the food's measures or one piece.
(double?, bool) gramsFor(IngredientLine p, CnfFood? f) {
  final q = p.qty;
  if (q == null) return (null, false);
  final u = p.unit;
  if (u == 'g') return (q, false);
  if (u == 'ml') return (q * (f?.gramsPerMl ?? 1.0), true);
  if (f == null) return (null, false);
  final size = RegExp(r'\b(small|medium|large|petite?s?|moyen(ne)?s?|grosses?)\b').firstMatch(_plain(p.name))?.group(1);
  final sizeEn = switch (size) { 'petit' || 'petite' || 'petits' || 'petites' => 'small', 'gros' || 'grosse' || 'grosses' => 'large', null => null, _ => size.startsWith('moyen') ? 'medium' : size };
  final piece = f.gramsPerPiece(size: sizeEn);
  if (piece != null) return (q * piece, true);
  return (null, false);
}

/// Gluten for an ingredient line: the gluten words plus plain "flour",
/// "bread", "pasta"... which in North America are wheat unless said otherwise.
Gluten ingredientGluten(String name, {String matched = '', Food? myFood}) {
  if (myFood != null && myFood.gluten != Gluten.unknown) return myFood.gluten;
  final free = RegExp(r'gluten[- ]free|sans gluten|\bgf\b|\btamari\b');
  // The recipe's own words win: "gluten-free flour blend" stays gluten-free
  // even when the closest food in the nutrient file is wheat flour.
  if (free.hasMatch(' ${_plain(name)} ')) return Gluten.free;
  name = '$name $matched';
  final s = ' ${_plain(name)} ';
  final r = glutenVerdict(labels: free.hasMatch(s) ? const ['en:gluten-free'] : const [], allergens: const [], traces: const [], ingredients: name);
  if (r.verdict == Gluten.contains) return Gluten.contains;
  // Always wheat or barley unless written as gluten-free.
  if (RegExp(r'\b(soy sauce|sauce soya|sauce soja|shoyu|beer|biere|seitan|teriyaki|hoisin)\b').hasMatch(s)) return Gluten.contains;
  if (!free.hasMatch(s)) {
    final grainFree = RegExp(r'\b(rice|riz|corn|mais|almond|amande|coconut|coco|potato|pomme de terre|tapioca|buckwheat|sarrasin|chickpea|pois chiche|sorghum|sorgho|millet|quinoa|teff|cassava|manioc|arrowroot|soy|soya|bean|lentil)\b');
    if (RegExp(r'\b(flour|farine)\b').hasMatch(s) && !grainFree.hasMatch(s)) return Gluten.contains;
    if (RegExp(r'\b(bread|pain|breadcrumbs?|chapelure|panko|pasta|pates|noodles?|nouilles|crackers?|biscuits?|cookies?|cake mix|croutons?|tortillas? de ble|cereal|cereales)\b').hasMatch(s) &&
        !grainFree.hasMatch(s)) {
      return Gluten.contains;
    }
    if (RegExp(r'\b(oats?|avoine|broth|bouillon|stock|baking powder|poudre a pate|spice mix|seasoning|assaisonnement|sauce|chocolate|chocolat|sausage|saucisse|chips?)\b').hasMatch(s)) {
      return Gluten.unsure;
    }
  }
  // Plain ingredients (sugar, eggs, milk, fruit...) without gluten words.
  return Gluten.free;
}

/// Worst gluten verdict of a list.
Gluten worstGluten(Iterable<Gluten> all) {
  if (all.contains(Gluten.contains)) return Gluten.contains;
  if (all.contains(Gluten.unsure) || all.contains(Gluten.unknown)) return Gluten.unsure;
  return all.isEmpty ? Gluten.unknown : Gluten.free;
}
