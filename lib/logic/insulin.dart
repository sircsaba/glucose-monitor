import '../data/nightscout.dart';
import 'profile.dart';

/// Insulin and carbs over a period: boluses, scheduled basal, temp basal
/// changes (from the "Temp Basal" treatments the loop logs), and ratios.
class InsulinTotals {
  final double bolus; // all boluses, SMB and automatic included
  final double autoBolus; // SMB / Loop automatic boluses
  final double carbs;
  final double baseBasal; // what the profile's basal schedule would give
  final double tempPlus; // extra from temp basals above the schedule
  final double tempMinus; // less (negative number) from temp basals below it
  final int carbEntries;
  final int bolusEntries;
  final double hours; // length of the period

  InsulinTotals({
    required this.bolus,
    required this.autoBolus,
    required this.carbs,
    required this.baseBasal,
    required this.tempPlus,
    required this.tempMinus,
    required this.carbEntries,
    required this.bolusEntries,
    required this.hours,
  });

  double get manualBolus => bolus - autoBolus;
  double get totalBasal => baseBasal + tempPlus + tempMinus;
  double get total => bolus + totalBasal;
  double get basalPct => total <= 0 ? 0 : totalBasal / total * 100;

  /// Grams of carbs per unit of manual bolus (what the boluses actually covered).
  double? get icrManual => manualBolus > 0.05 && carbs > 0 ? carbs / manualBolus : null;

  /// Grams per unit counting every bolus, automatic ones too.
  double? get icrAll => bolus > 0.05 && carbs > 0 ? carbs / bolus : null;

  /// Total daily dose scaled to 24 h (the period may be a day so far).
  double get tdd24 => hours <= 0 ? 0 : total * 24 / hours;

  /// Estimated ISF in mg/dL per unit with the 1800 rule (100 rule in mmol/L),
  /// from the total daily dose. Only meaningful over most of a day or more.
  double? get isfRule => tdd24 > 1 ? 1800 / tdd24 : null;

  /// Estimated carb ratio with the 500 rule, from the total daily dose.
  double? get icrRule => tdd24 > 1 ? 500 / tdd24 : null;
}

bool _isBolus(Treatment t) => (t.insulin ?? 0) > 0 && t.type != 'Temp Basal';

/// Totals between [from] and [to]. [treatments] must cover from a few hours
/// before [from] (a temp basal can start earlier), sorted by time.
InsulinTotals insulinTotals(List<Treatment> treatments, List<ProfileDoc> profiles, DateTime from, DateTime to) {
  var bolus = 0.0, auto = 0.0, carbs = 0.0;
  var carbN = 0, bolusN = 0;
  for (final t in treatments) {
    if (t.t.isBefore(from) || !t.t.isBefore(to)) continue;
    if (_isBolus(t)) {
      bolus += t.insulin!;
      bolusN++;
      if (t.isSmb) auto += t.insulin!;
    }
    if ((t.carbs ?? 0) > 0) {
      carbs += t.carbs!;
      carbN++;
    }
  }

  // Temp basals: each runs for its duration or until the next one starts.
  final temps = treatments.where((t) => t.type == 'Temp Basal' && t.absolute != null).toList();
  var base = 0.0, plus = 0.0, minus = 0.0;
  var k = 0;
  // One-minute steps are precise enough and simple.
  for (var m = from; m.isBefore(to); m = m.add(const Duration(minutes: 1))) {
    final sched = profileAt(profiles, m)?.basalAt(m) ?? 0;
    while (k + 1 < temps.length && !temps[k + 1].t.isAfter(m)) {
      k++;
    }
    double rate = sched;
    if (temps.isNotEmpty && !temps[k].t.isAfter(m)) {
      final tb = temps[k];
      final end = tb.t.add(Duration(seconds: ((tb.duration ?? 30) * 60).round()));
      if (m.isBefore(end)) rate = tb.absolute!;
    }
    base += sched / 60;
    final diff = (rate - sched) / 60;
    if (diff > 0) {
      plus += diff;
    } else {
      minus += diff;
    }
  }
  return InsulinTotals(
    bolus: bolus,
    autoBolus: auto,
    carbs: carbs,
    baseBasal: base,
    tempPlus: plus,
    tempMinus: minus,
    carbEntries: carbN,
    bolusEntries: bolusN,
    hours: to.difference(from).inMinutes / 60,
  );
}

/// The profile name in use at [t]: the latest Profile Switch treatment, else the
/// uploaded profile's name.
String profileNameAt(List<Treatment> treatments, List<ProfileDoc> profiles, DateTime t) {
  String? sw;
  DateTime? swAt;
  for (final x in treatments) {
    if (x.type == 'Profile Switch' && x.profile.isNotEmpty && !x.t.isAfter(t)) {
      sw = x.profile;
      swAt = x.t;
    }
  }
  final p = profileAt(profiles, t);
  if (sw != null && (p == null || !p.start.isAfter(swAt!))) return sw;
  return p?.name ?? sw ?? '';
}

/// Moments the profile changed between [from] and [to], with the new name.
List<MapEntry<DateTime, String>> profileChanges(List<Treatment> treatments, List<ProfileDoc> profiles, DateTime from, DateTime to) {
  final out = <MapEntry<DateTime, String>>[];
  for (final x in treatments) {
    if (x.type == 'Profile Switch' && x.profile.isNotEmpty && !x.t.isBefore(from) && x.t.isBefore(to)) {
      out.add(MapEntry(x.t, x.profile));
    }
  }
  // An uploaded profile with another name (Loop uploads one whenever settings change).
  final old = profiles.reversed.toList();
  for (var i = 1; i < old.length; i++) {
    final p = old[i];
    if (p.start.isBefore(from) || !p.start.isBefore(to)) continue;
    if (p.name != old[i - 1].name) out.add(MapEntry(p.start, p.name));
  }
  out.sort((a, b) => a.key.compareTo(b.key));
  return out;
}
