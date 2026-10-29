import 'dart:convert';

/// A recipe read from a web page, without AI: most recipe sites put the
/// recipe in the page in the standard schema.org "Recipe" format (that is how
/// search engines show recipe cards), so the title, servings, ingredients and
/// steps can be read as they are. Pages without it fall back to their
/// ingredient and step lists.
class WebRecipe {
  final String title;
  final List<String> ingredients;
  final List<String> steps;
  final double? servings;
  final String servingText;
  final int? prepMinutes, cookMinutes;
  final String url;
  const WebRecipe({
    required this.title,
    required this.ingredients,
    required this.steps,
    this.servings,
    this.servingText = '',
    this.prepMinutes,
    this.cookMinutes,
    this.url = '',
  });

  /// As text for the recipe reader (title, servings, ingredients, steps).
  String toText() => [
        title,
        if (servings != null) 'Makes ${servings! == servings!.roundToDouble() ? servings!.round() : servings}',
        '',
        'Ingredients',
        ...ingredients,
        '',
        'Directions',
        for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}',
      ].join('\n');
}

/// Reads the recipe from a page's HTML; null when the page has none.
WebRecipe? recipeFromHtml(String html, {String url = ''}) {
  for (final m in RegExp(r'''<script[^>]*type\s*=\s*["']?application/ld\+json["']?[^>]*>([\s\S]*?)</script>''', caseSensitive: false)
      .allMatches(html)) {
    Object? j;
    try {
      j = jsonDecode(_unCdata(m.group(1)!.trim()));
    } catch (_) {
      continue;
    }
    final r = _findRecipe(j);
    if (r != null) {
      final w = _fromSchema(r, url);
      if (w.ingredients.isNotEmpty) return w;
    }
  }
  return _fromMarkup(html, url);
}

String _unCdata(String s) => s.replaceAll(RegExp(r'^<!\[CDATA\[|\]\]>$'), '').replaceAll(RegExp(r'^\s*//\s*'), '');

Map? _findRecipe(Object? j) {
  if (j is List) {
    for (final x in j) {
      final r = _findRecipe(x);
      if (r != null) return r;
    }
  } else if (j is Map) {
    final t = j['@type'];
    if (t == 'Recipe' || (t is List && t.contains('Recipe'))) return j;
    for (final k in ['@graph', 'mainEntity', 'mainEntityOfPage', 'itemListElement', 'item']) {
      final r = _findRecipe(j[k]);
      if (r != null) return r;
    }
  }
  return null;
}

WebRecipe _fromSchema(Map r, String url) {
  final ing = <String>[];
  final ri = r['recipeIngredient'] ?? r['ingredients'];
  if (ri is List) {
    for (final x in ri) {
      final s = cleanText(x.toString());
      if (s.isNotEmpty) ing.add(s);
    }
  } else if (ri is String) {
    ing.addAll(ri.split(RegExp(r'\n|\r')).map(cleanText).where((s) => s.isNotEmpty));
  }
  final steps = <String>[];
  void addSteps(Object? x) {
    if (x == null) return;
    if (x is String) {
      final t = cleanText(x, keepLines: true);
      steps.addAll(t.split('\n').map((l) => l.trim().replaceFirst(RegExp(r'^(\d{1,2})[.)]\s+'), '')).where((l) => l.isNotEmpty));
    } else if (x is List) {
      for (final y in x) {
        addSteps(y);
      }
    } else if (x is Map) {
      if (x['itemListElement'] != null) {
        // A section ("For the sauce"): its name, then its steps.
        final name = cleanText((x['name'] ?? '').toString());
        if (name.isNotEmpty && x['@type'] == 'HowToSection') steps.add('$name:');
        addSteps(x['itemListElement']);
      } else {
        addSteps(x['text'] ?? x['name']);
      }
    }
  }

  addSteps(r['recipeInstructions']);
  final (servings, servingText) = _yield(r['recipeYield'] ?? r['yield']);
  final name = r['name'] is List ? (r['name'] as List).first : r['name'];
  return WebRecipe(
    title: cleanText((name ?? '').toString()),
    ingredients: ing,
    steps: steps,
    servings: servings,
    servingText: servingText,
    prepMinutes: isoMinutes(r['prepTime']),
    cookMinutes: isoMinutes(r['cookTime']),
    url: url,
  );
}

/// "4", "4 servings", ["4", "4 portions"], "Makes 12 muffins" -> (12, "muffin").
(double?, String) _yield(Object? y) {
  if (y is num) return (y.toDouble(), '');
  if (y is List) {
    for (final x in y) {
      final r = _yield(x);
      if (r.$1 != null) return r;
    }
    return (null, '');
  }
  final s = cleanText((y ?? '').toString());
  final m = RegExp(r'(\d+(?:[.,]\d+)?)(?:\s*(?:-|to|à)\s*\d+)?\s*([A-Za-zÀ-ÿ ]*)').firstMatch(s);
  if (m == null) return (null, '');
  final n = double.tryParse(m.group(1)!.replaceAll(',', '.'));
  var what = m.group(2)!.trim().toLowerCase();
  if (RegExp(r'^(servings?|portions?|people|personnes?|serves)?$').hasMatch(what)) what = '';
  // "muffins" -> "muffin"
  if (what.endsWith('s') && !what.endsWith('ss')) what = what.substring(0, what.length - 1);
  return (n, what);
}

/// ISO 8601 durations as minutes: "PT1H30M" -> 90.
int? isoMinutes(Object? v) {
  final m = RegExp(r'P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?').firstMatch((v ?? '').toString());
  if (m == null || m.group(0) == 'P' || m.group(0) == 'PT') return null;
  final d = int.tryParse(m.group(1) ?? '') ?? 0, h = int.tryParse(m.group(2) ?? '') ?? 0, mi = int.tryParse(m.group(3) ?? '') ?? 0;
  final t = d * 1440 + h * 60 + mi;
  return t > 0 ? t : null;
}

/// Pages without the standard format: microdata (itemprop) or the lists
/// that follow an "Ingredients" / "Directions" heading.
WebRecipe? _fromMarkup(String html, String url) {
  final body = html.replaceAll(RegExp(r'<(script|style|noscript)[\s\S]*?</\1>', caseSensitive: false), ' ');
  List<String> byProp(String prop) => [
        for (final m in RegExp('<([a-z0-9]+)[^>]*itemprop\\s*=\\s*["\']$prop["\'][^>]*>([\\s\\S]*?)</\\1>', caseSensitive: false).allMatches(body))
          cleanText(m.group(2)!)
      ].where((s) => s.isNotEmpty).toList();
  var ing = byProp('recipeIngredient');
  if (ing.isEmpty) ing = byProp('ingredients');
  var steps = byProp('recipeInstructions');
  if (ing.isEmpty) ing = _listAfter(body, r'ingr[eé]dients?');
  if (steps.isEmpty) steps = _listAfter(body, r'directions?|instructions?|method|preparation|pr[ée]paration|steps|[ée]tapes|mode de pr[ée]paration');
  if (ing.isEmpty) return null;
  final t = RegExp(r'<h1[^>]*>([\s\S]*?)</h1>', caseSensitive: false).firstMatch(body)?.group(1) ??
      RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html)?.group(1) ??
      '';
  return WebRecipe(title: cleanText(t).split(RegExp(r'\s[|–-]\s')).first, ingredients: ing, steps: steps, url: url);
}

/// The <li> items of the first list after a heading matching [head].
List<String> _listAfter(String body, String head) {
  final h = RegExp('<(h[1-6]|strong|b|p|div|span)[^>]*>\\s*(?:<[^>]+>\\s*)*(?:$head)\\s*:?\\s*(?:<[^>]+>\\s*)*</\\1>', caseSensitive: false).firstMatch(body);
  if (h == null) return [];
  final rest = body.substring(h.end);
  final list = RegExp(r'<(ul|ol)[^>]*>([\s\S]*?)</\1>', caseSensitive: false).firstMatch(rest);
  if (list == null || list.start > 4000) return [];
  return [
    for (final li in RegExp(r'<li[^>]*>([\s\S]*?)</li>', caseSensitive: false).allMatches(list.group(2)!)) cleanText(li.group(1)!)
  ].where((s) => s.isNotEmpty).toList();
}

const _entities = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'frac12': '½', 'frac14': '¼', 'frac34': '¾',
  'deg': '°', 'eacute': 'é', 'egrave': 'è', 'ecirc': 'ê', 'agrave': 'à', 'acirc': 'â', 'ccedil': 'ç', 'ocirc': 'ô', 'icirc': 'î',
  'ucirc': 'û', 'ugrave': 'ù', 'euml': 'ë', 'iuml': 'ï', 'rsquo': '’', 'lsquo': '‘', 'rdquo': '”', 'ldquo': '“', 'ndash': '–',
  'mdash': '—', 'hellip': '…', 'times': '×', 'Eacute': 'É',
};

/// Text of an HTML fragment: tags removed, entities decoded, spaces tidied.
String cleanText(String s, {bool keepLines = false}) {
  s = s.replaceAll(RegExp(r'<br\s*/?>|</p>|</li>|</div>', caseSensitive: false), keepLines ? '\n' : ' ');
  // Inline tags (bold, links...) vanish; other tags separate words.
  s = s.replaceAll(RegExp(r'</?(b|i|em|strong|span|a|u|sup|sub|small|mark)\b[^>]*>', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
  s = s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[A-Za-z]+\d*);'), (m) {
    final e = m.group(1)!;
    if (e.startsWith('#x')) return String.fromCharCode(int.tryParse(e.substring(2), radix: 16) ?? 32);
    if (e.startsWith('#')) return String.fromCharCode(int.tryParse(e.substring(1)) ?? 32);
    return _entities[e] ?? m.group(0)!;
  });
  s = s.replaceAll('\u00a0', ' ');
  if (keepLines) {
    return s.split('\n').map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim()).where((l) => l.isNotEmpty).join('\n');
  }
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}
