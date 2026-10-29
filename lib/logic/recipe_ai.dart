import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'food.dart';

/// Reads a recipe from photos (or pasted text) with an AI model, on the user's
/// own API key: ingredients, steps, servings and the nutrition of one serving.
/// The result is always shown to the user to check before it is saved.
class RecipeAi {
  static const _s = FlutterSecureStorage();
  static const keyName = 'gm_ai_key';
  static const modelName = 'gm_ai_model';
  static const defaultModel = 'claude-sonnet-5-5';

  static Future<String?> key() async {
    try {
      return await _s.read(key: keyName);
    } catch (_) {
      return null;
    }
  }

  static Future<String> model() async {
    try {
      final m = await _s.read(key: modelName);
      return (m == null || m.trim().isEmpty) ? defaultModel : m.trim();
    } catch (_) {
      return defaultModel;
    }
  }

  static Future<void> save(String? apiKey, String? model) async {
    try {
      if (apiKey == null || apiKey.trim().isEmpty) {
        await _s.delete(key: keyName);
      } else {
        await _s.write(key: keyName, value: apiKey.trim());
      }
      if (model == null || model.trim().isEmpty || model.trim() == defaultModel) {
        await _s.delete(key: modelName);
      } else {
        await _s.write(key: modelName, value: model.trim());
      }
    } catch (_) {}
  }

  static const _prompt = '''
You read recipes for a family that counts carbohydrates for insulin dosing (type 1 diabetes) and must avoid gluten (celiac).
The images (or text) show one recipe: the ingredient list and/or how to make it. Several images can be pages of the same recipe.

Return ONLY one JSON object, no text around it, with these keys:
{
  "name": "recipe name",
  "servings": number of servings the recipe makes (best estimate if not written),
  "servingText": "what one serving is, e.g. '1 muffin' or '1 cup (240 g)'",
  "servingGrams": weight of one serving in grams if you can estimate it, else null,
  "ingredients": [{"name": "...", "amount": "as written, e.g. '2 cups'", "grams": estimated grams or null,
                   "carbs": grams of carbohydrate in this amount, "energy": kcal, "protein": g, "fat": g, "fiber": g,
                   "gluten": "free" | "contains" | "unsure", "note": "short, only if useful"}],
  "perServing": {"carbs": g, "energy": kcal, "protein": g, "fat": g, "fiber": g, "sugars": g, "sodium": mg},
  "steps": ["step 1 ...", "step 2 ..."],
  "prepMinutes": number or null, "cookMinutes": number or null,
  "gluten": "free" | "contains" | "unsure",
  "glutenWhy": ["short reasons, e.g. 'soy sauce usually contains wheat: use tamari labelled gluten-free'"],
  "meals": subset of ["breakfast", "lunch", "supper", "snack"] that fit this dish,
  "category": "short category, e.g. 'Baking', 'Main dish'",
  "notes": "assumptions you made (for example which flour or size), in one or two sentences"
}

Rules:
- Carbohydrates are TOTAL carbohydrates (as on North American labels), from standard nutrition data (USDA / Canadian Nutrient File).
- perServing must equal the sum of the ingredients divided by servings.
- Gluten: wheat, barley, rye, spelt, malt, regular oats, soy sauce, many broths, beer, couscous, semolina = contains.
  Ingredients that are often but not always gluten-free (oats, bouillon, sauces, spice mixes, baking powder) = unsure
  unless written as gluten-free. The whole recipe is "free" only when every ingredient is free.
- Keep the steps as written (shortened only when very long), in the recipe's language.
- Numbers are plain numbers (no units, no ranges: use the middle).
''';

  /// Reads a recipe; throws with a readable message on failure.
  static Future<Food> read({List<Uint8List> images = const [], String text = ''}) async {
    final apiKey = await key();
    if (apiKey == null || apiKey.isEmpty) throw Exception('Enter your AI key first (Food › menu › Recipe reading)');
    if (images.isEmpty && text.trim().isEmpty) throw Exception('Nothing to read');
    final content = <Map<String, dynamic>>[];
    for (final b in images.take(6)) {
      content.add({
        'type': 'image',
        'source': {'type': 'base64', 'media_type': 'image/jpeg', 'data': base64Encode(_shrink(b))},
      });
    }
    if (text.trim().isNotEmpty) content.add({'type': 'text', 'text': 'Recipe text:\n${text.trim()}'});
    content.add({'type': 'text', 'text': _prompt});

    final http.Response r;
    try {
      r = await http
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'content-type': 'application/json',
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
              if (kIsWeb) 'anthropic-dangerous-direct-browser-access': 'true',
            },
            body: jsonEncode({
              'model': await model(),
              'max_tokens': 4000,
              'messages': [
                {'role': 'user', 'content': content}
              ],
            }),
          )
          .timeout(const Duration(seconds: 120));
    } catch (e) {
      throw Exception('Cannot reach the AI service: $e');
    }
    if (r.statusCode == 401) throw Exception('The AI key was refused: check it in Food › menu › Recipe reading');
    if (r.statusCode != 200) {
      var msg = 'error ${r.statusCode}';
      try {
        msg = (jsonDecode(r.body)['error']['message'] ?? msg).toString();
      } catch (_) {}
      throw Exception('The AI service answered: $msg');
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final out = StringBuffer();
    for (final c in (j['content'] as List? ?? const [])) {
      if (c is Map && c['type'] == 'text') out.write(c['text']);
    }
    return recipeFromJson(_json(out.toString()));
  }

  /// Photos are made smaller (max 1600 px, JPEG) before sending: cheaper, faster.
  static Uint8List _shrink(Uint8List b) {
    try {
      var im = img.decodeImage(b);
      if (im == null) return b;
      im = img.bakeOrientation(im);
      if (im.width > 1600 || im.height > 1600) {
        im = im.width >= im.height ? img.copyResize(im, width: 1600) : img.copyResize(im, height: 1600);
      }
      return Uint8List.fromList(img.encodeJpg(im, quality: 82));
    } catch (_) {
      return b;
    }
  }

  static Map<String, dynamic> _json(String s) {
    final a = s.indexOf('{'), b = s.lastIndexOf('}');
    if (a < 0 || b <= a) throw Exception('The AI did not return a recipe. Try a clearer photo.');
    try {
      return jsonDecode(s.substring(a, b + 1)) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('The AI answer could not be read. Try again.');
    }
  }
}

/// A Food (one serving) with its recipe, from the AI's JSON (also used by tests).
Food recipeFromJson(Map<String, dynamic> j) {
  final ps = j['perServing'] is Map ? Map<String, dynamic>.from(j['perServing'] as Map) : <String, dynamic>{};
  final grams = num_(j['servingGrams']);
  final g = Gluten.values.firstWhere((x) => x.name == j['gluten'], orElse: () => Gluten.unsure);
  final ings = [
    for (final i in (j['ingredients'] is List ? j['ingredients'] as List : const []))
      if (i is Map) Map<String, dynamic>.from(i)
  ];
  final steps = [for (final s in (j['steps'] is List ? j['steps'] as List : const [])) s.toString()];
  final n = Nutrition.fromJson(ps);
  final why = [for (final s in (j['glutenWhy'] is List ? j['glutenWhy'] as List : const [])) s.toString()];
  final bad = [for (final i in ings) if (i['gluten'] == 'contains' || i['gluten'] == 'unsure') i['name'].toString()];
  return Food(
    name: (j['name'] ?? 'Recipe').toString(),
    category: (j['category'] ?? '').toString(),
    portion: grams != null && grams > 0 ? grams : 1,
    unit: grams != null && grams > 0 ? 'g' : 'serving',
    portionText: (j['servingText'] ?? '1 serving').toString(),
    n: n,
    per100: grams != null && grams > 0 ? n.times(100 / grams) : const Nutrition(),
    gluten: g,
    glutenWhy: why.isNotEmpty ? why : (bad.isEmpty ? ['All ingredients are gluten-free'] : ['Check: ${bad.join(', ')}']),
    ingredients: ings.map((i) => '${i['amount'] ?? ''} ${i['name'] ?? ''}'.trim()).join('\n'),
    meals: [for (final m in (j['meals'] is List ? j['meals'] as List : const [])) if (mealTypes.contains(m)) m.toString()],
    source: 'recipe',
    notes: (j['notes'] ?? '').toString(),
    recipe: {
      'servings': num_(j['servings']) ?? 1,
      'servingText': (j['servingText'] ?? '').toString(),
      'ingredients': ings,
      'steps': steps,
      if (num_(j['prepMinutes']) != null) 'prepMinutes': num_(j['prepMinutes']),
      if (num_(j['cookMinutes']) != null) 'cookMinutes': num_(j['cookMinutes']),
    },
  );
}
