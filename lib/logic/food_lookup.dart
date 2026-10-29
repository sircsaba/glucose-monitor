import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'cnf.dart';
import 'food.dart';
import 'recipe_parse.dart';

/// Looking a food up by name: generic foods from the Canadian Nutrient File
/// (on the phone, no internet needed) and store products from Open Food Facts.

/// Everyday words the nutrient file does not use ("BBQ chicken" is grilled chicken).
String cnfQuery(String q) {
  var s = ' ${q.toLowerCase()} ';
  const swap = {
    'bbq': 'roasted', "bbq'd": 'roasted', 'barbecued': 'roasted', 'grilled': 'roasted', 'grille': 'roasted', 'grillé': 'roasted',
    'bbq-ed': 'roasted', 'au bbq': 'roasted', 'baked': 'roasted', 'rôti': 'roasted', 'roti': 'roasted',
    'fries': 'french fried', 'frites': 'french fried',
  };
  swap.forEach((k, v) => s = s.replaceAll(' $k ', ' $v '));
  return s.trim();
}

/// Generic foods for what was typed, the plain food first: "apple" gives
/// "Apple, raw" before apple strudel, "chicken breast" roasted before fried.
List<CnfFood> lookupGeneric(Cnf cnf, String typed, {int limit = 40}) {
  final q = cnfQuery(typed);
  final found = cnf.search(q, limit: limit + 20);
  final words = q.toLowerCase().split(RegExp(r'[^a-zà-ÿ0-9%]+')).where((w) => w.length > 1).toSet();
  double rank(int i, CnfFood f) {
    final en = f.en.toLowerCase();
    final head = en.split(',').first.trim();
    var r = i.toDouble();
    if (words.contains(head) || words.contains(head.replaceAll(RegExp(r's$'), '')) || words.any((w) => '${w}s' == head)) r -= 8;
    if (RegExp(r'\b(fried|breaded|battered|deli|honey glazed)\b').hasMatch(en) && !words.any((w) => en.contains(w) && 'fried breaded battered deli'.contains(w))) r += 6;
    if (RegExp(r'^(strudel|croissant|pie|muffin|cake|cookie|sauce|juice|babyfood|fast foods|restaurant)').hasMatch(en) && !words.contains(head)) r += 6;
    return r;
  }
  final ranked = [for (var i = 0; i < found.length; i++) (rank(i, found[i]), found[i])]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final r in ranked.take(limit)) r.$2];
}

/// A portion choice for a generic food.
class CnfPortion {
  final String label; // "1 breast"
  final double grams;
  const CnfPortion(this.label, this.grams);
}

List<CnfPortion> cnfPortions(CnfFood f) {
  final out = <CnfPortion>[];
  for (final m in f.measures) {
    final l = m.$1.replaceAllMapped(RegExp(r'^(\d+(?:\.\d+)?)(ml|g)\b'), (x) => '${x[1]} ${x[2]}');
    if (out.any((p) => p.label == l)) continue;
    out.add(CnfPortion(l, m.$3));
  }
  if (!out.any((p) => p.label == '100 g')) out.add(const CnfPortion('100 g', 100));
  // Pieces ("1 breast", "1 medium") first, then cups and spoons, 100 g last.
  int rank(CnfPortion p) {
    final d = p.label.toLowerCase();
    if (d == '100 g') return 3;
    if (RegExp(r'^\d+(\.\d+)?\s*(ml|g)\b').hasMatch(d)) return 2;
    return d.startsWith('1 ') ? 0 : 1;
  }
  out.sort((a, b) => rank(a).compareTo(rank(b)));
  return out;
}

/// A food of the nutrient file as one of my foods, for [grams] a portion.
Food foodFromCnf(CnfFood c, CnfPortion p, {String category = ''}) {
  final f = Food(
    name: c.en,
    category: category,
    portion: (p.grams * 10).round() / 10,
    unit: 'g',
    portionText: p.label == '100 g' ? '' : '${p.label} (${fmtAmount(p.grams.roundToDouble())} g)',
    per100: c.per100,
    n: c.per100.times(p.grams / 100),
    source: 'cnf',
    notes: 'Canadian Nutrient File (Health Canada), food ${c.id}: ${c.fr}',
  );
  final g = cnfGluten(c.en);
  f.gluten = g;
  f.glutenWhy = switch (g) {
    Gluten.free => ['Generic food with no gluten. Check the label of seasonings, sauces or breading'],
    Gluten.contains => ['Usually made with wheat, barley or rye'],
    _ => ['Generic food: check the label of what you buy'],
  };
  return f;
}

/// Gluten of a generic food, from its name.
Gluten cnfGluten(String en) {
  final s = en.toLowerCase();
  if (RegExp(r'gluten[- ]free').hasMatch(s)) return Gluten.free;
  if (RegExp(r'\b(breaded|battered|coated|pizza|sandwich|burger|hamburger|submarine|wrap|muffin|pancake|waffle|pie|pastry|'
          r'croissant|bagel|dumpling|lasagna|macaroni|spaghetti|pasta|noodle|couscous|bulgur|barley|rye|wheat|stuffing|pretzel)')
      .hasMatch(s)) {
    if (!RegExp(r'\b(rice|corn|buckwheat)\b').hasMatch(s)) return Gluten.contains;
  }
  if (RegExp(r'^(fast foods|restaurant)|\b(frozen dinner|meal|entree|soup|gravy|sauce|seasoned|marinated|glazed|stew|casserole|nuggets?|sausage|meatballs?|imitation)\b')
      .hasMatch(s)) {
    return Gluten.unsure;
  }
  return ingredientGluten(en, matched: en);
}

/// A store product found by name (enough to show; the full product comes by barcode).
class OffHit {
  final String code, name, brand, serving;
  final double? carbs100, kcal100;
  const OffHit(this.code, this.name, this.brand, this.serving, this.carbs100, this.kcal100);
}

/// Store products matching [q], Canadian ones first.
Future<List<OffHit>> searchOff(String q) async {
  final hits = <OffHit>[];
  final seen = <String>{};
  for (final host in ['ca.openfoodfacts.org', 'world.openfoodfacts.org']) {
    final uri = Uri.https(host, '/cgi/search.pl', {
      'search_terms': q,
      'search_simple': '1',
      'action': 'process',
      'json': '1',
      'page_size': '25',
      'fields': 'code,product_name,product_name_en,product_name_fr,brands,serving_size,nutriments',
    });
    final r = await http
        .get(uri, headers: kIsWeb ? const {} : const {'User-Agent': 'MonitorGlucose/1.0 (https://monitorglucose.ca)'})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('Open Food Facts answered with error ${r.statusCode}');
    final j = jsonDecode(r.body);
    for (final p in (j is Map ? j['products'] as List? : null) ?? const []) {
      if (p is! Map) continue;
      final code = (p['code'] ?? '').toString();
      final name = [p['product_name'], p['product_name_en'], p['product_name_fr']]
          .map((x) => (x ?? '').toString().trim())
          .firstWhere((x) => x.isNotEmpty, orElse: () => '');
      if (code.length < 8 || name.isEmpty || !seen.add(code)) continue;
      final n = p['nutriments'] is Map ? p['nutriments'] as Map : const {};
      double? d(Object? x) => x is num ? x.toDouble() : double.tryParse('${x ?? ''}');
      hits.add(OffHit(code, name, (p['brands'] ?? '').toString().split(',').first.trim(), (p['serving_size'] ?? '').toString(),
          d(n['carbohydrates_100g']), d(n['energy-kcal_100g'])));
    }
    if (hits.length >= 10) break;
  }
  return hits;
}
