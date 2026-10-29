import 'food.dart';

/// A school lunch prepared at home: the foods in the lunch box for one day.
/// At school, the child picks what she eats now; once sent (to Loop or logged)
/// those foods move to "Eaten" and cannot be picked again. Kept in the food
/// list of the site (type "schoollunch"), so every phone and the web app see it.
class LunchItem {
  final String key; // stable within the lunch
  final Food food;
  double amount; // in food.unit, what was packed
  double eaten; // how much of it was eaten so far
  LunchItem(this.key, this.food, this.amount, {this.eaten = 0});

  double get left => (amount - eaten) < 0.0001 ? 0 : amount - eaten;
  bool get done => left <= 0;
  Nutrition get leftNutrition => food.forAmount(left);

  Map<String, dynamic> toJson() => {'key': key, 'food': food.toJson(), 'amount': amount, 'eaten': eaten};

  static LunchItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final f = j['food'];
    if (f is! Map) return null;
    return LunchItem(
      (j['key'] ?? '').toString(),
      Food.fromJson(Map<String, dynamic>.from(f)),
      (num_(j['amount']) ?? 1).toDouble(),
      eaten: (num_(j['eaten']) ?? 0).toDouble(),
    );
  }
}

/// One time something was eaten.
class LunchEaten {
  final String key, name, unit;
  final double amount, carbs;
  final DateTime at;
  final String how; // 'loop' (sent to Loop) or 'logged'
  const LunchEaten(this.key, this.name, this.amount, this.unit, this.carbs, this.at, this.how);

  Map<String, dynamic> toJson() =>
      {'key': key, 'name': name, 'amount': amount, 'unit': unit, 'carbs': (carbs * 10).round() / 10, 'at': at.toUtc().toIso8601String(), 'how': how};

  static LunchEaten? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse((j['at'] ?? '').toString());
    if (at == null) return null;
    return LunchEaten((j['key'] ?? '').toString(), (j['name'] ?? '').toString(), (num_(j['amount']) ?? 0).toDouble(),
        (j['unit'] ?? '').toString(), (num_(j['carbs']) ?? 0).toDouble(), at.toLocal(), (j['how'] ?? '').toString());
  }
}

class SchoolLunch {
  String? id;
  final String date; // YYYY-MM-DD, local
  final List<LunchItem> items;
  final List<LunchEaten> eaten;
  Map<String, dynamic> _other;
  SchoolLunch(this.date, {this.id, List<LunchItem>? items, List<LunchEaten>? eaten, Map<String, dynamic>? other})
      : items = items ?? [],
        eaten = eaten ?? [],
        _other = other ?? {};

  static const type = 'schoollunch';

  static String dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static DateTime? dayOf(String key) => DateTime.tryParse(key);

  List<LunchItem> get waiting => [for (final i in items) if (!i.done) i];
  bool get isEmpty => items.isEmpty;

  /// Past day: what is still in the box came back home.
  bool get isPast => date.compareTo(dayKey(DateTime.now())) < 0;

  String newKey() {
    var n = items.length + 1;
    while (items.any((i) => i.key == 'i$n')) {
      n++;
    }
    return 'i$n';
  }

  void add(Food f, double amount) {
    final same = items.where((i) => i.food.id != null && i.food.id == f.id && !i.done && i.eaten == 0).firstOrNull;
    if (same != null) {
      same.amount += amount;
    } else {
      items.add(LunchItem(newKey(), f.copy(), amount));
    }
  }

  /// Marks [amounts] (key -> amount) as eaten now.
  void markEaten(Map<String, double> amounts, {required String how, DateTime? at}) {
    final when = at ?? DateTime.now();
    amounts.forEach((key, a) {
      final i = items.where((x) => x.key == key).firstOrNull;
      if (i == null || a <= 0) return;
      final take = a > i.left ? i.left : a;
      if (take <= 0) return;
      i.eaten += take;
      eaten.add(LunchEaten(key, i.food.name, take, i.food.unit, i.food.forAmount(take).carbs ?? 0, when, how));
    });
  }

  Map<String, dynamic> toJson() => {
        ..._other,
        if (id != null) '_id': id,
        'type': type,
        'name': 'School lunch $date',
        'date': date,
        'items': [for (final i in items) i.toJson()],
        'eaten': [for (final e in eaten) e.toJson()],
      };

  static SchoolLunch? fromJson(Map<String, dynamic> j) {
    final date = (j['date'] ?? '').toString();
    if (dayOf(date) == null) return null;
    final other = Map<String, dynamic>.from(j)..removeWhere((k, _) => const {'_id', 'type', 'name', 'date', 'items', 'eaten'}.contains(k));
    return SchoolLunch(
      date,
      id: j['_id']?.toString(),
      items: [for (final x in (j['items'] is List ? j['items'] as List : const [])) LunchItem.fromJson(x)].whereType<LunchItem>().toList(),
      eaten: [for (final x in (j['eaten'] is List ? j['eaten'] as List : const [])) LunchEaten.fromJson(x)].whereType<LunchEaten>().toList(),
      other: other,
    );
  }
}
