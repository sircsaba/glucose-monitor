import '../data/nightscout.dart';
import 'food.dart';

/// Carb entries and what was eaten.
///
/// Loop (or Trio, AAPS) owns its carb entries, so the app never changes them.
/// What was eaten is written as a Note at the same time: meal type, a few
/// words (food type) and, when picked on the Food screen, the foods with
/// their nutrition. Describing an entry again writes a newer note, and the
/// newest one counts (the older one is left, but ignored).

/// A carb entry from the loop or the app (not a note).
bool isCarbEntry(Treatment t) => (t.carbs ?? 0) > 0 && t.type != 'Note';

/// A note that says what was eaten.
bool isMealNote(Treatment t) => t.type == 'Note' && (t.foods.isNotEmpty || t.mealType.isNotEmpty || t.foodType.isNotEmpty);

/// A carb entry that says by itself what was eaten (sent from the Food screen).
bool _selfDescribed(Treatment t) => t.foods.isNotEmpty || t.mealType.isNotEmpty;

DateTime _when(Treatment n) => n.describedAt ?? n.t;

/// Each carb entry with the note that describes it (the newest, when it was
/// described more than once). A note goes with the nearest carb entry within
/// 10 minutes (a meal sent from the Food screen is logged when Loop confirms).
Map<Treatment, Treatment> mealNotes(List<Treatment> treatments) {
  final carbs = treatments.where(isCarbEntry).toList();
  final out = <Treatment, Treatment>{};
  for (final n in treatments.where(isMealNote)) {
    Treatment? near;
    var best = 601;
    for (final c in carbs) {
      final d = c.t.difference(n.t).inSeconds.abs();
      if (d < best) {
        best = d;
        near = c;
      }
    }
    if (near == null) continue;
    final had = out[near];
    if (had == null || _when(n).isAfter(_when(had))) out[near] = n;
  }
  return out;
}

/// The treatments without the notes replaced by a newer description of the
/// same carb entry (so a meal described twice is counted once).
List<Treatment> withoutReplacedNotes(List<Treatment> treatments) {
  final links = mealNotes(treatments);
  final kept = links.values.toSet();
  final carbs = treatments.where(isCarbEntry).toList();
  return [
    for (final t in treatments)
      if (!isMealNote(t) || kept.contains(t) || !carbs.any((c) => c.t.difference(t.t).inSeconds.abs() <= 600)) t,
  ];
}

/// Breakfast before 10:30, lunch until 14:30, supper 16:30 to 20:30, otherwise snack.
String guessMealType(DateTime t) {
  final m = t.hour * 60 + t.minute;
  if (m >= 300 && m < 630) return 'breakfast';
  if (m >= 630 && m < 870) return 'lunch';
  if (m >= 990 && m < 1230) return 'supper';
  return 'snack';
}

/// What a carb entry was, in words: "Lunch · Pizza · Bread, apple".
String mealText(Treatment carb, Treatment? note) {
  final src = note ?? (_selfDescribed(carb) ? carb : null);
  final type = src?.mealType ?? '';
  final words = (note?.foodType ?? '').trim();
  final foods = [for (final f in src?.foods ?? const <Map<String, dynamic>>[]) (f['name'] ?? '').toString().trim()]
    ..removeWhere((s) => s.isEmpty);
  return [
    if (type.isNotEmpty) mealLabels[type] ?? type,
    if (words.isNotEmpty) words,
    if (foods.isNotEmpty) foods.join(', '),
  ].join(' · ');
}

/// Whether a carb entry says what was eaten.
bool isDescribed(Treatment carb, Treatment? note) => note != null || _selfDescribed(carb);

/// One meal type over a period.
class MealTypeStats {
  final String type; // '' = not described
  int count = 0;
  double carbs = 0;
  MealTypeStats(this.type);
  double get avg => count == 0 ? 0 : carbs / count;
}

/// Carb entries by meal type (breakfast, lunch, supper, snack, then the
/// entries that say nothing, or say only in words).
List<MealTypeStats> mealTypeStats(List<Treatment> treatments) {
  final links = mealNotes(treatments);
  final by = {for (final k in [...mealTypes, '']) k: MealTypeStats(k)};
  for (final c in treatments.where(isCarbEntry)) {
    final n = links[c];
    var type = n?.mealType ?? (c.mealType.isNotEmpty ? c.mealType : '');
    if (!by.containsKey(type)) type = '';
    by[type]!
      ..count += 1
      ..carbs += c.carbs!;
  }
  return by.values.where((m) => m.count > 0).toList();
}
