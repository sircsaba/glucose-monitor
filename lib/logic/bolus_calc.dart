import 'dart:math' as math;

import '../state/app_state.dart';
import 'profile.dart';

/// A simple bolus calculation, like a pump's bolus wizard:
///   carbs ÷ ICR  +  (glucose − target) ÷ ISF  −  IOB
/// with the profile in use now, and Loop's override (insulin needs and
/// target) when one is running. Rounded down to 0.05 U, never below 0.
class BolusCalc {
  final double carbs; // g
  final double? bgMg;
  final DateTime? bgTime;
  final double? icr; // g/U, override applied
  final double? isf; // mg/dL per U, override applied
  final double? targetMg; // middle of the target range (Loop corrects to it)
  final double? targetLo, targetHi;
  final double iob;
  final String? overrideName;
  final double? overrideScale; // insulin needs, e.g. 0.5 = 50 %
  final double? loopRecommends;
  final bool useCorrection;
  final bool useIob;

  BolusCalc({
    required this.carbs,
    this.bgMg,
    this.bgTime,
    this.icr,
    this.isf,
    this.targetMg,
    this.targetLo,
    this.targetHi,
    this.iob = 0,
    this.overrideName,
    this.overrideScale,
    this.loopRecommends,
    this.useCorrection = true,
    this.useIob = true,
  });

  /// From what the app knows now: profile, latest reading, IOB, override.
  factory BolusCalc.now({double carbs = 0, double? bgMg, bool useCorrection = true, bool useIob = true}) {
    final now = DateTime.now();
    final prof = profileAt(app.profiles, now);
    final d = app.device;
    final l = app.latest;
    final fresh = l != null && now.difference(l.t).inMinutes < 15;
    double? scale;
    double? lo = prof?.targetLowAt(now), hi = prof?.targetHighAt(now);
    String? oname;
    if (d != null && d.overrideActive) {
      oname = d.overrideName;
      scale = d.overrideMultiplier;
      for (final p in prof?.presets ?? const <OverridePreset>[]) {
        if (p.name == d.overrideName) {
          scale ??= p.scale;
          if (p.targetLo != null && p.targetHi != null) {
            lo = p.targetLo;
            hi = p.targetHi;
          }
        }
      }
    }
    final sc = (scale == null || scale <= 0) ? 1.0 : scale;
    final icr0 = prof?.carbRatioAt(now);
    final isf0 = prof?.sensAt(now);
    return BolusCalc(
      carbs: carbs,
      bgMg: bgMg ?? (fresh ? l!.mg : null),
      bgTime: bgMg != null ? now : (fresh ? l!.t : null),
      // More insulin needed (scale > 1) = smaller ratios.
      icr: icr0 == null ? null : icr0 / sc,
      isf: isf0 == null ? null : isf0 / sc,
      targetMg: lo != null && hi != null ? (lo + hi) / 2 : (lo ?? hi),
      targetLo: lo,
      targetHi: hi,
      iob: d?.iob ?? 0,
      overrideName: oname,
      overrideScale: scale,
      loopRecommends: d?.recommendedBolus,
      useCorrection: useCorrection,
      useIob: useIob,
    );
  }

  BolusCalc copyWith({double? carbs, double? bgMg, bool? useCorrection, bool? useIob}) => BolusCalc(
        carbs: carbs ?? this.carbs,
        bgMg: bgMg ?? this.bgMg,
        bgTime: bgTime,
        icr: icr,
        isf: isf,
        targetMg: targetMg,
        targetLo: targetLo,
        targetHi: targetHi,
        iob: iob,
        overrideName: overrideName,
        overrideScale: overrideScale,
        loopRecommends: loopRecommends,
        useCorrection: useCorrection ?? this.useCorrection,
        useIob: useIob ?? this.useIob,
      );

  bool get hasProfile => icr != null && isf != null;
  double get carbDose => (icr == null || icr! <= 0) ? 0 : carbs / icr!;
  bool get canCorrect => bgMg != null && isf != null && isf! > 0 && targetMg != null;
  double get correction => canCorrect ? (bgMg! - targetMg!) / isf! : 0;
  double get iobUsed => useIob ? math.max(0, iob) : 0;
  double get raw => carbDose + (useCorrection ? correction : 0) - iobUsed;
  /// Suggested bolus, rounded down to 0.05 U.
  double get total => raw <= 0 ? 0 : (raw * 20).floor() / 20;
}
