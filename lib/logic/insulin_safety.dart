import '../data/nightscout.dart';
import 'glucose.dart';

/// Checks before insulin is sent to Loop: none below the low limit; a warning
/// to confirm when glucose is under the caution level, falling fast, when
/// Loop predicts a low, or when there is no recent reading.
class InsulinSafety {
  final String? block; // why no insulin can be sent now
  final List<String> warnings;
  const InsulinSafety(this.block, this.warnings);
  bool get ok => block == null && warnings.isEmpty;
}

InsulinSafety insulinSafety({
  required Entry? latest,
  required DeviceInfo? device,
  required double lowMg,
  required double cautionMg,
  required bool mmol,
  DateTime? now,
}) {
  final t = now ?? DateTime.now();
  String bg(double mg) => '${fmtBg(mg, mmol)} ${mmol ? 'mmol/L' : 'mg/dL'}';
  final warn = <String>[];
  if (latest == null) {
    return InsulinSafety(null, ['No glucose reading: check her glucose before giving insulin.']);
  }
  final age = t.difference(latest.t).inMinutes;
  if (age > 15) warn.add('The last reading is $age minutes old (${bg(latest.mg)}): check her glucose first.');
  if (age <= 15 && latest.mg < lowMg) {
    return InsulinSafety('Glucose is ${bg(latest.mg)}, under your limit of ${bg(lowMg)}: no insulin is sent.', const []);
  }
  if (latest.mg < cautionMg) warn.add('Glucose is ${bg(latest.mg)}, under ${bg(cautionMg)}.');
  final d = latest.direction;
  if (age <= 15 && (d == 'DoubleDown' || d == 'SingleDown')) {
    warn.add('Glucose is falling fast.');
  } else if (age <= 15 && d == 'FortyFiveDown' && latest.mg < cautionMg + 36) {
    warn.add('Glucose is going down.');
  }
  final pred = device?.mainPrediction ?? const <double>[];
  if (pred.isNotEmpty) {
    // Loop's prediction is every 5 minutes: the next 3 hours.
    var minV = pred.first;
    var minI = 0;
    for (var i = 0; i < pred.length && i < 36; i++) {
      if (pred[i] < minV) {
        minV = pred[i];
        minI = i;
      }
    }
    if (minV < lowMg) warn.add('Loop predicts ${bg(minV)} in about ${minI * 5} minutes.');
  }
  return InsulinSafety(null, warn);
}
