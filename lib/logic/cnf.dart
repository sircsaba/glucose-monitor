import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'food.dart';

/// One food of the Canadian Nutrient File (Health Canada, 2015, Open
/// Government Licence - Canada): nutrients per 100 g and household measures.
class CnfFood {
  final int id;
  final String en, fr;
  final int group;
  final Nutrition per100;
  final List<(String en, String fr, double grams)> measures;
  late final String _search = _norm('$en $fr');
  late final Set<String> _words = _search.split(' ').where((w) => w.isNotEmpty).map(_stem).toSet();
  CnfFood(this.id, this.en, this.fr, this.group, this.per100, this.measures);

  /// Grams in one millilitre, from the measures given in ml (null if none).
  double? get gramsPerMl {
    double? best;
    var bestMl = 0.0;
    for (final m in measures) {
      final mm = RegExp(r'^(\d+(?:\.\d+)?)\s*ml\b').firstMatch(m.$1.toLowerCase());
      if (mm == null) continue;
      final ml = double.parse(mm.group(1)!);
      // Plain or "packed" measures are fine; "sifted", "melted", "whipped" less so.
      final rest = m.$1.toLowerCase().substring(mm.end).trim();
      final penalty = RegExp(r'sifted|melted|whipped|shredded|grated|crumbled').hasMatch(rest) ? 0.5 : 1.0;
      if (ml * penalty > bestMl) {
        bestMl = ml * penalty;
        best = m.$3 / ml;
      }
    }
    return best;
  }

  /// Grams of one piece ("1 medium", "1 egg", "1 slice"...), preferring [size].
  double? gramsPerPiece({String? size}) {
    (String, String, double)? pick;
    for (final m in measures) {
      final d = m.$1.toLowerCase();
      if (!d.startsWith('1 ') || RegExp(r'^\d+(\.\d+)?\s*(ml|g)\b').hasMatch(d.substring(2))) continue;
      if (size != null && d.contains(size)) return m.$3;
      if (pick == null || d.contains('medium')) pick = m;
    }
    return pick?.$3;
  }
}

class Cnf {
  final List<CnfFood> foods;
  final Map<int, CnfFood> byId;
  /// Food group names (English, French) by group number.
  final Map<int, (String, String)> groups;
  Cnf(this.foods, [this.groups = const {}]) : byId = {for (final f in foods) f.id: f};

  static Cnf? _cache;
  static Future<Cnf> load() async => _cache ??= parse(await rootBundle.loadString('assets/cnf.json'));

  static Cnf parse(String json) {
    final j = jsonDecode(json) as Map<String, dynamic>;
    final keys = [for (final k in j['keys'] as List) k.toString()];
    final ms = [for (final m in j['measures'] as List) (m[0].toString(), m[1].toString())];
    final foods = <CnfFood>[];
    for (final r in j['foods'] as List) {
      final nv = r[4] as List;
      var n = Nutrition.empty;
      for (var i = 0; i < keys.length && i < nv.length; i++) {
        final x = nv[i];
        if (x is num) n = n.withValue(keys[i], x.toDouble());
      }
      foods.add(CnfFood((r[0] as num).toInt(), r[1].toString(), r[2].toString(), (r[3] as num).toInt(), n, [
        for (final m in r[5] as List) (ms[(m[0] as num).toInt()].$1, ms[(m[0] as num).toInt()].$2, (m[1] as num).toDouble())
      ]));
    }
    final groups = <int, (String, String)>{};
    final g = j['groups'];
    if (g is Map) {
      g.forEach((k, v) {
        final id = int.tryParse(k.toString());
        if (id != null && v is List && v.length >= 2) groups[id] = (v[0].toString(), v[1].toString());
      });
    }
    return Cnf(foods, groups);
  }

  /// Best matches for an ingredient name (English or French), best first.
  List<CnfFood> search(String query, {int limit = 20}) {
    final q = _norm(query);
    if (q.isEmpty) return [];
    final words = q.split(' ').where((w) => w.length > 1 && !_stop.contains(w)).map(_stem).toList();
    final pref = _preferred(words.where((w) => !_describe.contains(w)).toSet());
    if (words.isEmpty && pref == null) return [];
    final scored = <(double, CnfFood)>[];
    for (final f in foods) {
      var hit = 0.0;
      for (final w in words) {
        if (f._words.contains(w)) {
          hit += 1;
        } else if (w.length >= 4 && f._words.any((x) => x.startsWith(w))) {
          hit += 0.6;
        }
      }
      if (hit == 0 && f.id != pref) continue;
      var score = hit / words.length.clamp(1, 99);
      score -= 0.02 * (f._words.length - words.length).clamp(0, 30); // simpler names first
      if (f.id == pref) score += 2;
      // Plain ingredients before dishes, fast food and baby food.
      if (RegExp(r'^(fast foods|babyfood|restaurant|meal|soup|dinner|candies|snacks)', caseSensitive: false).hasMatch(f.en)) score -= 0.4;
      if (!q.contains('cooked') && !q.contains('cuit') && f._search.contains(' raw')) score += 0.05;
      scored.add((score, f));
    }
    // Same score: keep the file's order (sort is not stable on its own).
    final order = {for (var k = 0; k < scored.length; k++) scored[k].$2.id: k};
    scored.sort((a, b) {
      final c = b.$1.compareTo(a.$1);
      return c != 0 ? c : order[a.$2.id]!.compareTo(order[b.$2.id]!);
    });
    return [for (final s in scored.take(limit)) s.$2];
  }

  /// The food Monitor Glucose picks first for a common ingredient.
  /// Only when the ingredient's main words are exactly one of the phrases
  /// ("large eggs" -> eggs; "almond flour" is not "flour").
  static int? _preferred(Set<String> core) {
    if (core.isEmpty) return null;
    for (final e in _prefer.entries) {
      for (final phrase in e.key.split('|')) {
        final pw = phrase.split(' ').where((w) => !_stop.contains(w)).map(_stem).toSet();
        if (pw.length == core.length && pw.containsAll(core)) return e.value;
      }
    }
    return null;
  }

  // Common recipe ingredients (English | French) -> Canadian Nutrient File id.
  // The most specific names come first.
  static const _prefer = {
    'rice flour|farine de riz': 4429,
    'brown rice flour|farine de riz brun': 4451,
    'whole wheat flour|farine de ble entier': 4500,
    'cake flour': 4446,
    'self rising flour|self raising flour': 4444,
    'all purpose flour|flour|farine tout usage|farine': 501865,
    'cornstarch|corn starch|fecule de mais': 4419,
    'cornmeal|semoule de mais': 4470,
    'quinoa flour|farine de quinoa': 6187,
    'brown sugar|cassonade|sucre brun': 4317,
    'icing sugar|powdered sugar|sucre a glacer': 4319,
    'maple syrup|sirop d erable': 4326,
    'sugar|sucre': 4318,
    'honey|miel': 4294,
    'baking soda|bicarbonate de soude': 4005,
    'baking powder|poudre a pate': 4003,
    'salt|sel': 214,
    'unsalted butter|beurre non sale': 92,
    'butter|beurre': 118,
    'canola oil|vegetable oil|oil|huile de canola|huile vegetale|huile': 451,
    'olive oil|huile d olive': 422,
    'vanilla|vanilla extract|vanille|extrait de vanille': 216,
    'egg|eggs|oeuf|oeufs': 125,
    'milk|lait': 61,
    'whole milk|lait entier': 113,
    'whipping cream|creme a fouetter|creme 35': 138,
    'plain yogurt|yogurt|yogourt|yogourt nature': 502170,
    'cocoa|cocoa powder|cacao|poudre de cacao': 4223,
    'chocolate chips|pepites de chocolat': 4148,
    'banana|bananas|banane|bananes': 1704,
    'cinnamon|cannelle': 178,
    'garlic powder|poudre d ail': 188,
    'garlic|ail': 2394,
    'onion|onions|oignon|oignons': 2401,
    'oats|rolled oats|flocons d avoine|avoine': 4421,
    'lemon juice|jus de citron': 1589,
    'cheddar|cheddar cheese|fromage cheddar': 119,
    'parmesan|parmesan cheese|parmesan rape': 39,
    'mozzarella|fromage mozzarella': 110,
    'peanut butter|beurre d arachide': 6289,
    'ketchup': 2494,
    'mayonnaise|mayo': 531,
    'tamari': 3329,
    'soy sauce|sauce soya': 3403,
    'white rice|rice|riz blanc|riz': 4523,
    'quinoa': 5917,
    'ground beef|boeuf hache': 2690,
    'bacon': 1936,
    'potato|potatoes|pomme de terre|pommes de terre': 2417,
    'sweet potato|patate douce': 2240,
    'tomato|tomatoes|tomate|tomates': 2460,
    'spaghetti': 4515,
  };
}

/// Words that describe an ingredient without changing what it is.
const _describe = {
  'large', 'medium', 'small', 'fresh', 'ripe', 'chopped', 'diced', 'sliced', 'minced', 'softened', 'melted', 'room',
  'temperature', 'packed', 'sifted', 'unsifted', 'grated', 'shredded', 'beaten', 'cold', 'warm', 'hot', 'extra',
  'gros', 'grosse', 'moyen', 'moyenne', 'petit', 'petite', 'frais', 'fraiche', 'mur', 'hache', 'haches', 'tranche', 'fondu',
  'mou', 'ramolli', 'rape', 'battu', 'battus', 'froid', 'tiede', 'chaud', 'tasse', 'cup',
};

const _stop = {'of', 'the', 'and', 'or', 'a', 'de', 'du', 'des', 'la', 'le', 'les', 'et', 'ou', 'en', 'with', 'avec', 'to', 'taste', 'for', 'pour'};

String _norm(String s) {
  var t = s.toLowerCase();
  const from = 'àâäáãçéèêëíìîïñóòôöõúùûüœ';
  const to = 'aaaaaceeeeiiiinooooouuuuo';
  final b = StringBuffer();
  for (final ch in t.split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  t = b.toString().replaceAll(RegExp(r'[^a-z0-9%]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return t;
}

/// Very small stemmer: plurals ("eggs", "tomatoes", "oeufs").
String _stem(String w) {
  if (w.length > 4 && w.endsWith('oes')) return w.substring(0, w.length - 2);
  if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) return w.substring(0, w.length - 1);
  return w;
}
