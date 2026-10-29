import 'package:flutter/material.dart';

import '../logic/bolus_calc.dart';
import '../logic/glucose.dart';
import '../state/app_state.dart';
import '../state/settings.dart';
import 'common.dart';

String _g(double mg) => '${fmtBg(mg, app.mmol)} ${unitLabel(app.mmol)}';
String _isf(double mgPerU) => app.mmol ? '${(mgPerU / mgPerMmol).toStringAsFixed(1)} mmol/L/U' : '${mgPerU.round()} mg/dL/U';
String _u(double u) => '${u < 0 ? '−' : ''}${u.abs().toStringAsFixed(2)} U';

/// The calculation, line by line.
class BolusSummary extends StatelessWidget {
  final BolusCalc c;
  const BolusSummary(this.c, {super.key});

  @override
  Widget build(BuildContext context) {
    Widget row(String a, String b, {String? sub, bool strong = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a, style: TextStyle(fontSize: 13, fontWeight: strong ? FontWeight.w700 : FontWeight.w400)),
                if (sub != null) Text(sub, style: const TextStyle(color: kMuted, fontSize: 11)),
              ]),
            ),
            Text(b, style: kMono.copyWith(fontSize: strong ? 15 : 13, fontWeight: strong ? FontWeight.w700 : FontWeight.w400, color: color)),
          ]),
        );
    if (!c.hasProfile) {
      return const Text('No therapy profile on the site yet (carb ratio and ISF are needed).', style: TextStyle(color: kAmber, fontSize: 13));
    }
    final rows = <Widget>[
      if (c.overrideName != null && c.overrideName!.isNotEmpty)
        row('Override: ${c.overrideName}', c.overrideScale == null ? '' : '${(c.overrideScale! * 100).round()} %',
            sub: 'Insulin needs and target of the override are used', color: kAmber),
      row('Carbs', c.carbs > 0 ? _u(c.carbDose) : '0.00 U',
          sub: c.carbs > 0 ? '${c.carbs.round()} g ÷ ICR ${c.icr!.toStringAsFixed(1)} g/U' : 'No carbs'),
      if (!c.canCorrect)
        row('Correction', '—', sub: c.bgMg == null ? 'No recent glucose reading' : 'No target in the profile')
      else
        row('Correction', c.useCorrection ? _u(c.correction) : 'off',
            sub: '(${_g(c.bgMg!)} − target ${_g(c.targetMg!)}) ÷ ISF ${_isf(c.isf!)}'
                '${c.targetLo != null && c.targetHi != null ? '\nTarget = middle of ${fmtBg(c.targetLo!, app.mmol)}–${fmtBg(c.targetHi!, app.mmol)}' : ''}'),
      row('Insulin on board', c.useIob ? _u(-c.iobUsed) : 'off', sub: 'IOB ${c.iob.toStringAsFixed(2)} U${c.iob < 0 ? ' (below zero: not added)' : ''}'),
      const Divider(height: 14),
      row('Suggested bolus', '${fmtU(c.total)} U', strong: true, color: kAccent,
          sub: c.raw < 0 ? 'The calculation is below zero (${_u(c.raw)}): no bolus' : 'Rounded down to 0.05 U'),
      if (c.loopRecommends != null)
        row('Loop recommends now', '${fmtU(c.loopRecommends!)} U', sub: 'Loop\'s own suggestion with its prediction, without new carbs'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

/// Bolus calculator: carbs and glucose in, the suggested bolus out, with
/// every step shown. Nothing is sent from here.
class BolusCalcScreen extends StatefulWidget {
  /// Carbs to start with (from a meal on the Food screen).
  final double carbs;
  const BolusCalcScreen({super.key, this.carbs = 0});
  @override
  State<BolusCalcScreen> createState() => _BolusCalcScreenState();
}

class _BolusCalcScreenState extends State<BolusCalcScreen> {
  late double _carbs = widget.carbs.roundToDouble();
  double? _bg; // mg/dL, null = latest reading
  bool _corr = true;
  bool _iob = true;

  @override
  Widget build(BuildContext context) {
    final mmol = app.mmol;
    return Scaffold(
      appBar: AppBar(title: const Text('Bolus calculator')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final c = BolusCalc.now(carbs: _carbs, bgMg: _bg, useCorrection: _corr, useIob: _iob);
          final bg = _bg ?? c.bgMg;
          return ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 30), children: [
            Section(children: [
              StepRow(
                label: 'Carbs',
                value: '${_carbs.round()} g',
                onMinus: () => setState(() => _carbs = (_carbs - 5).clamp(0, 300)),
                onPlus: () => setState(() => _carbs = (_carbs + 5).clamp(0, 300)),
              ),
              StepRow(
                label: 'Glucose',
                hint: _bg == null ? 'Latest reading' : 'Changed by you',
                value: bg == null ? '—' : fmtBg(bg, mmol),
                onMinus: () => setState(() => _bg = ((bg ?? 100) - (mmol ? mgPerMmol / 10 : 1)).clamp(40.0, 400.0)),
                onPlus: () => setState(() => _bg = ((bg ?? 100) + (mmol ? mgPerMmol / 10 : 1)).clamp(40.0, 400.0)),
              ),
              SwitchRow(label: 'Correct to the target', value: _corr, onChanged: (v) => setState(() => _corr = v)),
              SwitchRow(label: 'Subtract insulin on board', value: _iob, onChanged: (v) => setState(() => _iob = v)),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
              child: BolusSummary(c),
            ),
            const SizedBox(height: 12),
            const Text(
              'A simple calculation from the profile (carb ratio, ISF, target) and IOB. Loop\'s own bolus '
              'recommendation also uses its glucose prediction and carbs on board, so it can differ. Always check before giving insulin.',
              style: TextStyle(color: kMuted, fontSize: 12, height: 1.4),
            ),
          ]);
        },
      ),
    );
  }
}
