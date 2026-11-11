import 'package:flutter/material.dart';

import '../data/nightscout.dart';
import '../logic/food.dart';
import '../logic/glucose.dart';
import '../logic/meal_link.dart';
import '../plus.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'food_screen.dart';

/// Says what a carb entry was: meal type, a few words, and (on the Food
/// screen) the foods. The entry itself is not changed: Loop keeps its carbs.
/// Returns true when something was saved.
Future<bool> describeCarbEntry(BuildContext context, Treatment carb, {Treatment? note}) async {
  final t24 = app.settings.flag('time24');
  final fromSelf = note == null && (carb.foods.isNotEmpty || carb.mealType.isNotEmpty);
  final src = note ?? (fromSelf ? carb : null);
  var type = (src?.mealType ?? '').isNotEmpty ? src!.mealType : guessMealType(carb.t);
  final words = TextEditingController(text: note?.foodType ?? '');
  final foods = [for (final f in src?.foods ?? const <Map<String, dynamic>>[]) (f['name'] ?? '').toString()]..removeWhere((s) => s.isEmpty);
  // Loop's own food type (often an emoji for how fast it absorbs).
  final loopType = carb.foodType.trim();

  final go = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(c).bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${fmtClock(carb.t, t24)} · ${(carb.carbs ?? 0).round()} g carbs',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            Text(
              '${carb.t.year}-${two(carb.t.month)}-${two(carb.t.day)}'
              '${carb.enteredBy.isNotEmpty ? ' · from ${carb.enteredBy}' : ''}'
              '${loopType.isNotEmpty ? ' · food type in Loop: $loopType' : ''}',
              style: const TextStyle(color: kMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            const Text('Meal', style: TextStyle(color: kMuted, fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in mealTypes) ChoiceChip(label: Text(mealLabels[m]!), selected: type == m, onSelected: (_) => set(() => type = m)),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: words,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'What was eaten (for example: pizza, pasta and salad)'),
            ),
            if (foods.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Foods: ${foods.join(', ')}', style: const TextStyle(fontSize: 13)),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(c, 'foods'),
              icon: const Icon(Icons.restaurant_menu),
              label: Text(foods.isEmpty ? 'Pick the foods or a saved meal' : 'Pick the foods again'),
            ),
            const SizedBox(height: 6),
            const Text(
              'Saved as a note at the time of the entry: the carbs in Loop do not change. '
              'Foods picked on the Food screen also add calories, protein and fat to the Nutrition report.',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
          ]),
        ),
      ),
    ),
  );
  if (go == null || !context.mounted) return false;
  final text = words.text.trim();

  if (go == 'foods') {
    if (!app.meal.isEmpty) {
      app.meal.items.clear();
      app.mealChanged();
    }
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => FoodScreen(attachTo: carb, attachMealType: type, attachFoodType: text)),
    );
    return done == true;
  }

  // Save: a newer note replaces the older one (the foods already picked stay).
  try {
    await app.postTreatment({
      'eventType': 'Note',
      'created_at': carb.t.toUtc().toIso8601String(),
      'enteredBy': app.settings.str('enteredBy').isEmpty ? kAppName : app.settings.str('enteredBy'),
      'notes': [mealLabels[type] ?? type, if (text.isNotEmpty) text, if (foods.isNotEmpty) 'Meal: ${foods.join(', ')}'].join(' · '),
      'mealType': type,
      if (text.isNotEmpty) 'foodType': text,
      // Foods of an earlier note stay (not those sent with the carbs: already counted).
      if (note != null && note.foods.isNotEmpty) 'foods': note.foods,
      if (note != null && note.foods.isNotEmpty) 'nutrition': note.nutrition.toJson(),
      'describedAt': DateTime.now().toUtc().toIso8601String(),
    });
    if (context.mounted) toast(context, 'Saved for the ${fmtClock(carb.t, t24)} entry');
    return true;
  } catch (e) {
    if (context.mounted) toast(context, e.toString());
    return false;
  }
}

/// Carb entries of the last day that do not say what was eaten (newest first).
List<Treatment> carbsToDescribe({int max = 5}) {
  final ts = app.treatments;
  final links = mealNotes(ts);
  final since = DateTime.now().subtract(const Duration(hours: 24));
  final out = [
    for (final c in ts.where(isCarbEntry))
      if (c.t.isAfter(since) && !isDescribed(c, links[c])) c,
  ]..sort((a, b) => b.t.compareTo(a.t));
  return out.take(max).toList();
}
