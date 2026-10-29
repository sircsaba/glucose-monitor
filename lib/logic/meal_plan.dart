/// A plan for a meal's insulin: all now, a prebolus and the rest later, a
/// prebolus a set time before the meal, or waiting until glucose rises above a
/// level. Each step rings when it is due; a person confirms it (Face ID in
/// Monitor Glucose Plus) before anything is sent. Nothing is given by itself.
enum MealStepState { pending, done, skipped }

class MealStep {
  final String label; // "Prebolus", "Rest of the bolus", "Bolus"
  final double units;
  final bool withCarbs; // the meal's carbs go with this step
  DateTime? at; // due at this time (null: no time)
  final double? aboveMg; // due when a reading is at or above this
  final DateTime? giveUpAt; // with aboveMg: ring anyway at this time
  MealStepState state;

  MealStep({
    required this.label,
    required this.units,
    this.withCarbs = false,
    this.at,
    this.aboveMg,
    this.giveUpAt,
    this.state = MealStepState.pending,
  });

  bool get isNow => at == null && aboveMg == null;

  Map<String, dynamic> toJson() => {
        'label': label,
        'units': units,
        'withCarbs': withCarbs,
        if (at != null) 'at': at!.toIso8601String(),
        if (aboveMg != null) 'aboveMg': aboveMg,
        if (giveUpAt != null) 'giveUpAt': giveUpAt!.toIso8601String(),
        'state': state.name,
      };

  factory MealStep.fromJson(Map<String, dynamic> j) => MealStep(
        label: (j['label'] ?? '').toString(),
        units: (j['units'] as num?)?.toDouble() ?? 0,
        withCarbs: j['withCarbs'] == true,
        at: j['at'] == null ? null : DateTime.tryParse(j['at'].toString()),
        aboveMg: (j['aboveMg'] as num?)?.toDouble(),
        giveUpAt: j['giveUpAt'] == null ? null : DateTime.tryParse(j['giveUpAt'].toString()),
        state: MealStepState.values.firstWhere((s) => s.name == j['state'], orElse: () => MealStepState.pending),
      );
}

/// Why a step is due now, or null if it isn't.
String? stepDueReason(MealStep s, {required DateTime now, required DateTime planStarted, double? latestMg, DateTime? latestTime}) {
  if (s.state != MealStepState.pending || s.isNow) return null;
  if (s.at != null && !now.isBefore(s.at!)) return 'It is time';
  if (s.aboveMg != null && latestMg != null && latestTime != null && latestTime.isAfter(planStarted) && latestMg >= s.aboveMg! - 0.01) {
    return 'Glucose is above the level you set';
  }
  if (s.giveUpAt != null && !now.isBefore(s.giveUpAt!)) return 'The waiting time is over (glucose is still below the level)';
  return null;
}

class MealPlan {
  final DateTime started;
  final double carbs;
  final String note; // what is eaten
  final List<Map<String, dynamic>> foods;
  final List<MealStep> steps;

  MealPlan({required this.started, required this.carbs, this.note = '', this.foods = const [], required this.steps});

  MealStep? get next {
    for (final s in steps) {
      if (s.state == MealStepState.pending) return s;
    }
    return null;
  }

  bool get finished => next == null;
  double get totalUnits => steps.fold(0.0, (a, s) => a + s.units);

  Map<String, dynamic> toJson() => {
        'started': started.toIso8601String(),
        'carbs': carbs,
        'note': note,
        'foods': foods,
        'steps': [for (final s in steps) s.toJson()],
      };

  factory MealPlan.fromJson(Map<String, dynamic> j) => MealPlan(
        started: DateTime.tryParse((j['started'] ?? '').toString()) ?? DateTime.now(),
        carbs: (j['carbs'] as num?)?.toDouble() ?? 0,
        note: (j['note'] ?? '').toString(),
        foods: [for (final f in (j['foods'] is List ? j['foods'] as List : const [])) if (f is Map) Map<String, dynamic>.from(f)],
        steps: [for (final s in (j['steps'] is List ? j['steps'] as List : const [])) if (s is Map) MealStep.fromJson(Map<String, dynamic>.from(s))],
      );
}

double _r05(double u) => (u * 20).round() / 20;

/// Everything now, with the carbs.
List<MealStep> planAllNow(double total) => [MealStep(label: 'Bolus', units: _r05(total), withCarbs: true)];

/// [first] units now with the carbs, the rest [afterMin] minutes later.
List<MealStep> planSplit(double total, double first, int afterMin, DateTime now) {
  final a = _r05(first.clamp(0, total));
  final rest = _r05(total - a);
  return [
    MealStep(label: 'Prebolus', units: a, withCarbs: true),
    if (rest > 0) MealStep(label: 'Rest of the bolus', units: rest, at: now.add(Duration(minutes: afterMin))),
  ];
}

/// Prebolus of [first] units [preMin] minutes before [mealTime] (with the
/// carbs), the rest at the meal.
List<MealStep> planAtTime(double total, double first, DateTime mealTime, int preMin) {
  final a = _r05(first.clamp(0, total));
  final rest = _r05(total - a);
  return [
    MealStep(label: 'Prebolus', units: a, withCarbs: true, at: mealTime.subtract(Duration(minutes: preMin))),
    if (rest > 0) MealStep(label: 'Rest of the bolus', units: rest, at: mealTime),
  ];
}

/// Wait: ring when glucose is at or above [mg] (or after [maxWaitMin] anyway),
/// then the whole bolus with the carbs.
List<MealStep> planWhenAbove(double total, double mg, int maxWaitMin, DateTime now) => [
      MealStep(label: 'Bolus', units: _r05(total), withCarbs: true, aboveMg: mg, giveUpAt: now.add(Duration(minutes: maxWaitMin))),
    ];
