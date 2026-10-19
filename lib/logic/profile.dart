/// Therapy profiles as Loop, Trio and AAPS upload them: basal rates, carb
/// ratios and insulin sensitivity by time of day.
class TimedValue {
  final int sec; // seconds after midnight
  final double v;
  const TimedValue(this.sec, this.v);
}

/// One of Loop's override presets (Settings › Overrides), from the profile.
class OverridePreset {
  final String name;
  final String symbol;
  final int? durationMin; // null = until cancelled
  final double? scale; // insulin needs, 1 = 100 %
  final double? targetLo, targetHi; // mg/dL
  const OverridePreset(this.name, this.symbol, this.durationMin, this.scale, this.targetLo, this.targetHi);
  String get label => symbol.isEmpty ? name : '$symbol $name';
}

class ProfileDoc {
  final String name;
  final DateTime start;
  final List<TimedValue> basal; // U/h
  final List<TimedValue> carbRatio; // g/U
  final List<TimedValue> sens; // mg/dL per U
  final List<TimedValue> targetLow; // mg/dL
  final List<TimedValue> targetHigh; // mg/dL
  /// Loop only: what remote commands need.
  final bool isLoop;
  final List<OverridePreset> presets;
  final String? deviceToken;
  final String? bundleId;
  final double? maxBolus;
  ProfileDoc({
    required this.name,
    required this.start,
    required this.basal,
    required this.carbRatio,
    required this.sens,
    this.targetLow = const [],
    this.targetHigh = const [],
    this.isLoop = false,
    this.presets = const [],
    this.deviceToken,
    this.bundleId,
    this.maxBolus,
  });

  static double? _at(List<TimedValue> list, DateTime t) {
    if (list.isEmpty) return null;
    final s = t.hour * 3600 + t.minute * 60 + t.second;
    var v = list.first.v;
    for (final x in list) {
      if (x.sec <= s) v = x.v;
    }
    return v;
  }

  double basalAt(DateTime t) => _at(basal, t) ?? 0;
  double? carbRatioAt(DateTime t) => _at(carbRatio, t);
  double? sensAt(DateTime t) => _at(sens, t);
  double? targetLowAt(DateTime t) => _at(targetLow, t);
  double? targetHighAt(DateTime t) => _at(targetHigh, t);

  /// Scheduled basal for one whole day, in units.
  double get dailyBasal {
    if (basal.isEmpty) return 0;
    var total = 0.0;
    for (var i = 0; i < basal.length; i++) {
      final end = i + 1 < basal.length ? basal[i + 1].sec : 86400;
      total += basal[i].v * (end - basal[i].sec) / 3600;
    }
    return total;
  }
}

double? _num(dynamic x) => x is num ? x.toDouble() : (x is String ? double.tryParse(x) : null);

List<TimedValue> _list(dynamic x, {double factor = 1}) {
  if (x is! List) return const [];
  final out = <TimedValue>[];
  for (final e in x) {
    if (e is! Map) continue;
    var sec = _num(e['timeAsSeconds'])?.toInt();
    if (sec == null && e['time'] is String) {
      final p = (e['time'] as String).split(':');
      sec = (int.tryParse(p[0]) ?? 0) * 3600 + (p.length > 1 ? (int.tryParse(p[1]) ?? 0) * 60 : 0);
    }
    final v = _num(e['value']);
    if (sec == null || v == null) continue;
    out.add(TimedValue(sec, v * factor));
  }
  out.sort((a, b) => a.sec.compareTo(b.sec));
  return out;
}

DateTime? _date(dynamic x) {
  if (x is num) return DateTime.fromMillisecondsSinceEpoch(x.toInt());
  if (x is String) return DateTime.tryParse(x)?.toLocal();
  return null;
}

/// Profile documents from /api/v1/profile.json, newest first.
List<ProfileDoc> parseProfiles(dynamic j) {
  final out = <ProfileDoc>[];
  final list = j is List ? j : (j is Map ? [j] : const []);
  for (final d in list) {
    if (d is! Map) continue;
    final store = d['store'];
    if (store is! Map || store.isEmpty) continue;
    var name = (d['defaultProfile'] ?? '').toString();
    if (!store.containsKey(name)) name = store.keys.first.toString();
    final p = store[name];
    if (p is! Map) continue;
    final units = (p['units'] ?? d['units'] ?? '').toString().toLowerCase();
    final sensList = _list(p['sens']);
    // ISF in mmol/L per unit when the profile is in mmol (values under ~20).
    final mmol = units.startsWith('mmol') || (sensList.isNotEmpty && sensList.every((x) => x.v < 20));
    final start = _date(d['startDate']) ?? _date(d['created_at']) ?? _date(d['mills']);
    if (start == null) continue;
    final ls = d['loopSettings'];
    final presets = <OverridePreset>[];
    if (ls is Map && ls['overridePresets'] is List) {
      for (final o in ls['overridePresets'] as List) {
        if (o is! Map || o['name'] == null) continue;
        final dur = _num(o['duration']);
        final tr = o['targetRange'];
        presets.add(OverridePreset(
          o['name'].toString(),
          (o['symbol'] ?? '').toString(),
          dur == null || dur <= 0 ? null : (dur / 60).round(),
          _num(o['insulinNeedsScaleFactor']),
          tr is List && tr.length == 2 ? _num(tr[0]) : null,
          tr is List && tr.length == 2 ? _num(tr[1]) : null,
        ));
      }
    }
    out.add(ProfileDoc(
      name: name,
      start: start,
      basal: _list(p['basal']),
      carbRatio: _list(p['carbratio']),
      sens: mmol ? _list(p['sens'], factor: 18.0182) : sensList,
      targetLow: _targets(p['target_low']),
      targetHigh: _targets(p['target_high']),
      isLoop: ls is Map,
      presets: presets,
      deviceToken: ls is Map ? ls['deviceToken']?.toString() : null,
      bundleId: ls is Map ? ls['bundleIdentifier']?.toString() : null,
      maxBolus: ls is Map ? _num(ls['maximumBolus']) : null,
    ));
  }
  out.sort((a, b) => b.start.compareTo(a.start));
  return out;
}

/// The profile in use at [t] (profiles newest first).
ProfileDoc? profileAt(List<ProfileDoc> profiles, DateTime t) {
  for (final p in profiles) {
    if (!p.start.isAfter(t)) return p;
  }
  return profiles.isEmpty ? null : profiles.last;
}

/// Target values in mg/dL (mmol/L ones, under 30, are converted).
List<TimedValue> _targets(dynamic x) {
  final l = _list(x);
  if (l.isNotEmpty && l.every((v) => v.v < 30)) return _list(x, factor: 18.0182);
  return l;
}
