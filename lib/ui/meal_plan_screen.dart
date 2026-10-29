import 'package:flutter/material.dart';

import '../logic/bolus_calc.dart';
import '../logic/glucose.dart';
import '../logic/meal_plan.dart';
import '../plus.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'remote_screen.dart';

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String stepWhen(MealStep s, bool mmol) {
  if (s.isNow) return 'now';
  if (s.aboveMg != null) {
    return 'when glucose is ${fmtBg(s.aboveMg!, mmol)} or more${s.giveUpAt != null ? ' (or at ${_hm(s.giveUpAt!)})' : ''}';
  }
  return 'at ${_hm(s.at!)}';
}

/// Plans the insulin for a meal: all now, prebolus + rest later, prebolus a
/// set time before the meal, or wait until glucose rises above a level.
class MealPlanScreen extends StatefulWidget {
  final double carbs;
  final String note;
  final List<Map<String, dynamic>> foods;
  const MealPlanScreen({super.key, required this.carbs, this.note = '', this.foods = const []});
  @override
  State<MealPlanScreen> createState() => _MealPlanScreenState();
}

class _MealPlanScreenState extends State<MealPlanScreen> {
  int _mode = 0; // 0 all now, 1 part now + rest later, 2 at a time, 3 when above
  double? _total; // null = the calculator's suggestion
  double _firstPct = 50;
  int _afterMin = 15;
  late DateTime _mealTime = _round5(DateTime.now().add(const Duration(minutes: 30)));
  int _preMin = 15;
  late double _aboveMg = app.range.yelLo + 18; // 1 mmol/L above the low end of green
  int _maxWait = 45;

  static DateTime _round5(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, (t.minute / 5).ceil() * 5);

  @override
  Widget build(BuildContext context) {
    final mmol = app.mmol;
    return Scaffold(
      appBar: AppBar(title: const Text('Meal insulin')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final c = BolusCalc.now(carbs: widget.carbs);
          final total = _total ?? c.total;
          final first = (total * _firstPct / 100 * 20).round() / 20;
          final now = DateTime.now();
          final steps = switch (_mode) {
            1 => planSplit(total, first, _afterMin, now),
            2 => planAtTime(total, _firstPct >= 100 ? total : first, _mealTime, _preMin),
            3 => planWhenAbove(total, _aboveMg, _maxWait, now),
            _ => planAllNow(total),
          };
          final l = app.latest;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
            if (app.mealPlan != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('A meal plan is already running. Starting this one replaces it.', style: const TextStyle(color: kAmber)),
              ),
            Section(title: 'Calculation', children: [
              _row('Carbs', '${widget.carbs.round()} g'),
              _row('Carb ratio (ICR)', c.icr == null ? 'no profile' : '${fmtAmount1(c.icr!)} g/U'),
              _row('For the carbs', '${fmtU(c.carbDose)} U'),
              _row('Glucose', c.bgMg == null ? 'no recent reading' : '${fmtBg(c.bgMg!, mmol)} ${unitLabel(mmol)}'),
              _row('Target', c.targetMg == null ? '–' : fmtBg(c.targetMg!, mmol)),
              _row('Sensitivity (ISF)', c.isf == null ? '–' : '${fmtBg(c.isf!, mmol)} ${unitLabel(mmol)}/U'),
              _row('Correction', '${c.correction >= 0 ? '+' : ''}${fmtU(c.correction)} U'),
              _row('Insulin on board', '−${fmtU(c.iobUsed)} U'),
              if (c.overrideName != null) _row('Override', '${c.overrideName}${c.overrideScale != null ? ' ${(c.overrideScale! * 100).round()} %' : ''}'),
              StepRow(
                label: 'Total bolus',
                hint: _total == null ? 'The calculator\'s suggestion' : 'Changed by you',
                value: '${fmtU(total)} U',
                onMinus: () => setState(() => _total = ((total - 0.05).clamp(0.0, 30.0) * 20).round() / 20),
                onPlus: () => setState(() => _total = ((total + 0.05).clamp(0.0, 30.0) * 20).round() / 20),
                last: true,
              ),
            ]),
            if (c.loopRecommends != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('Loop\'s own recommendation right now: ${fmtU(c.loopRecommends!)} U (it knows the carbs only once they are entered).',
                    style: const TextStyle(color: kMuted, fontSize: 12.5)),
              ),
            const Text('When', style: TextStyle(color: kMuted, fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (i, t) in const ['All now', 'Part now, rest later', 'Before the meal at a time', 'When glucose rises above'].indexed)
                ChoiceChip(label: Text(t), selected: _mode == i, onSelected: (_) => setState(() => _mode = i)),
            ]),
            const SizedBox(height: 12),
            if (_mode == 1 || _mode == 2)
              Section(children: [
                StepRow(
                  label: _mode == 1 ? 'Prebolus now' : 'Prebolus',
                  hint: '${_firstPct.round()} % of the total',
                  value: '${fmtU(_firstPct >= 100 ? total : first)} U',
                  onMinus: () => setState(() => _firstPct = (_firstPct - 10).clamp(10, 100)),
                  onPlus: () => setState(() => _firstPct = (_firstPct + 10).clamp(10, 100)),
                ),
                if (_mode == 1)
                  StepRow(
                    label: 'Rest after',
                    value: '$_afterMin min',
                    onMinus: () => setState(() => _afterMin = (_afterMin - 5).clamp(5, 120)),
                    onPlus: () => setState(() => _afterMin = (_afterMin + 5).clamp(5, 120)),
                    last: true,
                  ),
                if (_mode == 2) ...[
                  StepRow(
                    label: 'Meal at',
                    value: _hm(_mealTime),
                    onMinus: () => setState(() {
                      final t = _mealTime.subtract(const Duration(minutes: 5));
                      if (t.isAfter(now)) _mealTime = t;
                    }),
                    onPlus: () => setState(() => _mealTime = _mealTime.add(const Duration(minutes: 5))),
                  ),
                  StepRow(
                    label: 'Prebolus before the meal',
                    value: '$_preMin min',
                    onMinus: () => setState(() => _preMin = (_preMin - 5).clamp(0, 60)),
                    onPlus: () => setState(() => _preMin = (_preMin + 5).clamp(0, 60)),
                    last: true,
                  ),
                ],
              ]),
            if (_mode == 3)
              Section(children: [
                StepRow(
                  label: 'Ring when glucose is at least',
                  value: fmtBg(_aboveMg, mmol),
                  onMinus: () => setState(() => _aboveMg = (_aboveMg - (mmol ? mgPerMmol / 10 : 2)).clamp(54.0, 250.0)),
                  onPlus: () => setState(() => _aboveMg = (_aboveMg + (mmol ? mgPerMmol / 10 : 2)).clamp(54.0, 250.0)),
                ),
                StepRow(
                  label: 'Ring anyway after',
                  hint: 'If glucose stays below, to decide what to do',
                  value: '$_maxWait min',
                  onMinus: () => setState(() => _maxWait = (_maxWait - 5).clamp(10, 180)),
                  onPlus: () => setState(() => _maxWait = (_maxWait + 5).clamp(10, 180)),
                  last: true,
                ),
              ]),
            if (_mode == 3 && l != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('Now ${fmtBg(l.mg, mmol)} ${unitLabel(mmol)}${l.mg >= _aboveMg ? ': already above, it will ring at the next reading' : ''}',
                    style: const TextStyle(color: kMuted)),
              ),
            const Text('The plan', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final s in steps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text('• ${s.label}: ${fmtU(s.units)} U${s.withCarbs ? ' with the ${widget.carbs.round()} g carbs' : ''}, ${stepWhen(s, mmol)}',
                    style: const TextStyle(fontSize: 15)),
              ),
            const SizedBox(height: 8),
            Text(
              kRemote
                  ? 'Each step rings when it is due and asks you to confirm (Face ID) before it is sent to Loop. Nothing is given by itself. '
                      'Keep Monitor Glucose open (the night view keeps the screen on) so the alarm can ring.'
                  : 'Each step rings when it is due, as a reminder to give it on the pump or in Loop. '
                      'Keep Monitor Glucose open (the night view keeps the screen on) so the alarm can ring.',
              style: const TextStyle(color: kMuted, fontSize: 12.5, height: 1.45),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: total <= 0 && widget.carbs <= 0 ? null : () => _start(steps),
                child: Text(steps.first.isNow ? (kRemote ? 'Start: send the first step' : 'Start the plan') : 'Start the plan',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _row(String a, String b) => RowBox(
        child: Row(children: [Expanded(child: Text(a)), Text(b, style: kMono.copyWith(fontSize: 15))]),
      );

  Future<void> _start(List<MealStep> steps) async {
    final plan = MealPlan(started: DateTime.now(), carbs: widget.carbs, note: widget.note, foods: widget.foods, steps: steps);
    app.startMealPlan(plan);
    final first = steps.first;
    if (first.isNow) {
      if (kRemote) {
        await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => stepSendScreen(plan, first)));
      } else {
        app.mealStepFinished(first);
        if (mounted) Navigator.pop(context);
        if (mounted) toast(context, 'Give ${fmtU(first.units)} U now');
      }
    } else {
      Navigator.pop(context);
      toast(context, 'Meal plan started: it rings ${stepWhen(first, app.mmol)}');
    }
  }
}

String fmtAmount1(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

/// Loop remote screen filled in for this step; the step is done once sent.
Widget stepSendScreen(MealPlan plan, MealStep s) => RemoteScreen(
      carbs: s.withCarbs ? plan.carbs : null,
      carbInsulin: s.withCarbs ? s.units : null,
      bolus: s.withCarbs ? null : s.units,
      mealNote: s.withCarbs && plan.note.isNotEmpty ? plan.note : null,
      onSent: (_) => app.mealStepFinished(s),
    );

/// Shown (with the alarm) when a step of the meal plan is due.
class MealStepScreen extends StatelessWidget {
  final MealStep step;
  const MealStepScreen({super.key, required this.step});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final plan = app.mealPlan;
        final mmol = app.mmol;
        final l = app.latest;
        final c = BolusCalc.now(carbs: step.withCarbs ? (plan?.carbs ?? 0) : 0);
        void close() {
          app.player.stop();
          Navigator.maybePop(context);
        }

        return Scaffold(
          appBar: AppBar(title: const Text('Meal insulin'), automaticallyImplyLeading: false),
          body: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 40), children: [
            Icon(Icons.restaurant_menu, size: 56, color: kAccent.withValues(alpha: 0.9)),
            const SizedBox(height: 10),
            Text('${step.label}: ${fmtU(step.units)} U', textAlign: TextAlign.center, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
            if (step.withCarbs && plan != null)
              Text('with ${plan.carbs.round()} g carbs', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Text(app.dueReason ?? '', textAlign: TextAlign.center, style: const TextStyle(color: kMuted, fontSize: 15)),
            const SizedBox(height: 14),
            if (l != null)
              Text('Glucose now ${fmtBg(l.mg, mmol)} ${unitLabel(mmol)} ${arrowText(l.direction)}',
                  textAlign: TextAlign.center, style: kMono.copyWith(fontSize: 20, color: app.colorFor(l.mg))),
            if (c.hasProfile)
              Text('The calculator now says ${fmtU(c.total)} U${step.withCarbs ? '' : ' (correction − IOB)'}',
                  textAlign: TextAlign.center, style: const TextStyle(color: kMuted)),
            if (plan != null && plan.note.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 10), child: Text(plan.note, textAlign: TextAlign.center, style: const TextStyle(color: kMuted, fontSize: 13))),
            const SizedBox(height: 24),
            if (kRemote && plan != null)
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: () {
                    app.player.stop();
                    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => stepSendScreen(plan, step)));
                  },
                  icon: const Icon(Icons.send),
                  label: const Text('Send to Loop (confirm)', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              )
            else
              SizedBox(
                height: 56,
                child: FilledButton(
                  onPressed: () {
                    app.mealStepFinished(step);
                    close();
                  },
                  child: const Text('I gave it', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    app.snoozeMealStep(step, 5);
                    close();
                  },
                  child: const Text('In 5 minutes'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    app.mealStepFinished(step, skipped: true);
                    close();
                  },
                  child: const Text('Skip this step'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () {
                app.cancelMealPlan();
                close();
              },
              child: const Text('Cancel the whole plan'),
            ),
          ]),
        );
      },
    );
  }
}

/// One line about the running meal plan, with a cancel button.
class MealPlanBanner extends StatelessWidget {
  const MealPlanBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final p = app.mealPlan;
    final s = p?.next;
    if (p == null || s == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(color: kAccent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12), border: Border.all(color: kAccent)),
      child: Row(children: [
        const Icon(Icons.alarm, color: kAccent),
        const SizedBox(width: 8),
        Expanded(child: Text('Meal plan: ${s.label.toLowerCase()} ${fmtU(s.units)} U ${stepWhen(s, app.mmol)}')),
        TextButton(onPressed: app.cancelMealPlan, child: const Text('Cancel')),
      ]),
    );
  }
}
