import '../data/nightscout.dart';
import 'food.dart';

/// One day: carbs from every carb entry (Loop, Trio, AAPS, the app), and the
/// rest of the nutrition from the meals put together on the Food screen.
class NutritionDay {
  final DateTime day;
  double carbs = 0;
  Nutrition meals = Nutrition.empty;
  int mealCount = 0; // meals with foods
  NutritionDay(this.day);
}

/// What one meal did to glucose in the 3 hours after it.
class MealRise {
  final Treatment meal;
  final double? startMg;
  final double? peakMg;
  final int? minutesToPeak;
  final bool overlap; // another meal within 2 hours after it (the rise is shared)
  const MealRise(this.meal, this.startMg, this.peakMg, this.minutesToPeak, this.overlap);
  double? get rise => startMg == null || peakMg == null ? null : peakMg! - startMg!;
  String get description => meal.foods.map((f) => f['name']).whereType<Object>().join(', ');
  double get carbs => meal.nutrition.carbs ?? meal.carbs ?? 0;
}

class FoodRise {
  final String name;
  final int meals;
  final double avgRise; // mg/dL
  final double avgCarbs; // g of the meals it was in
  const FoodRise(this.name, this.meals, this.avgRise, this.avgCarbs);
}

class NutritionReport {
  final List<NutritionDay> days;
  final List<MealRise> meals; // biggest rise first
  final List<FoodRise> foods; // biggest average rise first (foods eaten at least twice)
  NutritionReport(this.days, this.meals, this.foods);

  int get daysWithMeals => days.where((d) => d.mealCount > 0).length;
  double get avgCarbs => days.isEmpty ? 0 : days.fold(0.0, (a, d) => a + d.carbs) / days.length;
  /// Average of the days that have meals from the Food screen.
  Nutrition get avgMeals {
    final n = days.where((d) => d.mealCount > 0).toList();
    if (n.isEmpty) return Nutrition.empty;
    return n.fold(Nutrition.empty, (a, d) => a + d.meals).times(1 / n.length);
  }
}

bool _isCarbs(Treatment t) => (t.carbs ?? 0) > 0 && t.type != 'Note';

NutritionReport nutritionReport({required DateTime from, required DateTime to, required List<Treatment> treatments, required List<Entry> entries}) {
  final days = <NutritionDay>[];
  for (var d = DateTime(from.year, from.month, from.day); !d.isAfter(to); d = DateTime(d.year, d.month, d.day + 1)) {
    days.add(NutritionDay(d));
  }
  NutritionDay? dayOf(DateTime t) {
    for (final d in days) {
      if (d.day.year == t.year && d.day.month == t.month && d.day.day == t.day) return d;
    }
    return null;
  }

  final inRange = treatments.where((t) => !t.t.isBefore(from) && !t.t.isAfter(to)).toList()..sort((a, b) => a.t.compareTo(b.t));
  for (final t in inRange) {
    final d = dayOf(t.t);
    if (d == null) continue;
    if (_isCarbs(t)) d.carbs += t.carbs!;
    if (t.isMeal) {
      d.mealCount++;
      d.meals = d.meals + t.nutrition;
    }
  }

  final sorted = [...entries]..sort((a, b) => a.t.compareTo(b.t));
  final meals = inRange.where((t) => t.isMeal).toList();
  final carbTimes = inRange.where((t) => _isCarbs(t) || t.isMeal).map((t) => t.t).toList();
  final rises = <MealRise>[];
  for (final m in meals) {
    // Glucose when eating: the last reading in the 15 minutes before (or 5 after).
    double? start;
    for (final e in sorted) {
      final dt = e.t.difference(m.t).inMinutes;
      if (dt < -15) continue;
      if (dt > 5) break;
      start = e.mg;
      if (dt >= 0) break;
    }
    double? peak;
    DateTime? peakAt;
    final end = m.t.add(const Duration(hours: 3));
    for (final e in sorted) {
      if (!e.t.isAfter(m.t)) continue;
      if (e.t.isAfter(end)) break;
      if (peak == null || e.mg > peak) {
        peak = e.mg;
        peakAt = e.t;
      }
    }
    final overlap = carbTimes.any((c) => c.isAfter(m.t.add(const Duration(minutes: 20))) && c.isBefore(m.t.add(const Duration(hours: 2))));
    rises.add(MealRise(m, start, peak, peakAt?.difference(m.t).inMinutes, overlap));
  }
  rises.sort((a, b) => (b.rise ?? -999).compareTo(a.rise ?? -999));

  final byFood = <String, List<MealRise>>{};
  for (final r in rises) {
    if (r.rise == null || r.overlap) continue;
    for (final f in r.meal.foods) {
      final name = (f['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      byFood.putIfAbsent(name, () => []).add(r);
    }
  }
  final foods = [
    for (final e in byFood.entries)
      if (e.value.length >= 2)
        FoodRise(e.key, e.value.length, e.value.fold(0.0, (a, r) => a + r.rise!) / e.value.length,
            e.value.fold(0.0, (a, r) => a + r.carbs) / e.value.length),
  ]..sort((a, b) => b.avgRise.compareTo(a.avgRise));
  return NutritionReport(days, rises, foods);
}
