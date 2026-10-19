import 'package:flutter/material.dart';

import '../data/nightscout.dart';
import '../logic/bolus_calc.dart';
import '../logic/glucose.dart';
import '../plus.dart';
import '../state/app_state.dart';
import '../state/settings.dart';
import 'bolus_calc_view.dart';
import 'common.dart';
import 'remote_screen.dart';

class _EventType {
  final String label;
  final String nsType;
  final bool carbs;
  final bool insulin;
  final bool target;
  final bool bg;
  const _EventType(this.label, this.nsType, {this.carbs = false, this.insulin = false, this.target = false, this.bg = false});
}

const _types = [
  _EventType('Meal', 'Meal Bolus', carbs: true, insulin: true),
  _EventType('Correction', 'Correction Bolus', insulin: true),
  _EventType('Carbs only', 'Carb Correction', carbs: true),
  _EventType('Temp target', 'Temporary Target', target: true),
  _EventType('BG check', 'BG Check', bg: true),
  _EventType('Site change', 'Site Change'),
  _EventType('Sensor start', 'Sensor Start'),
  _EventType('Insulin change', 'Insulin Change'),
  _EventType('Note', 'Note'),
];

class TreatScreen extends StatefulWidget {
  const TreatScreen({super.key});
  @override
  State<TreatScreen> createState() => _TreatScreenState();
}

class _TreatScreenState extends State<TreatScreen> {
  int _type = 0;
  int _carbs = 30;
  double _insulin = 3.0;
  double _target = 144; // mg/dL
  int _duration = 60;
  double _bg = 126; // mg/dL
  int _minutesAgo = 0;
  final _notes = TextEditingController();
  bool _busy = false;
  bool _form = !kRemote; // Plus / web: the two big buttons first

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = _types[_type];
    final when = DateTime.now().subtract(Duration(minutes: _minutesAgo));
    final m = <String, dynamic>{
      'eventType': t.nsType,
      'created_at': when.toUtc().toIso8601String(),
      'enteredBy': app.settings.str('enteredBy').isEmpty ? 'Monitor Glucose app' : app.settings.str('enteredBy'),
    };
    if (t.carbs) m['carbs'] = _carbs;
    if (t.insulin) m['insulin'] = double.parse(_insulin.toStringAsFixed(2));
    if (t.target) {
      m['targetTop'] = _target.round();
      m['targetBottom'] = _target.round();
      m['duration'] = _duration;
      m['units'] = 'mg/dl';
    }
    if (t.bg) {
      m['glucose'] = _bg.round();
      m['glucoseType'] = 'Finger';
      m['units'] = 'mg/dl';
    }
    if (_notes.text.trim().isNotEmpty) m['notes'] = _notes.text.trim();
    setState(() => _busy = true);
    try {
      await app.postTreatment(m);
      if (!mounted) return;
      _notes.clear();
      toast(context, '${t.label} saved');
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final t = _types[_type];
        final mmol = app.mmol;
        final allowed = app.settings.flag('allowTreatments');
        final l = app.latest;
        final d = app.device;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Row(children: [
              const Expanded(child: Text('Add treatment', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600))),
              if (l != null)
                Text('${fmtBg(l.mg, mmol)} ${arrowText(l.direction)}', style: kMono.copyWith(color: app.colorFor(l.mg), fontSize: 16)),
            ]),
            const SizedBox(height: 14),
            if (kRemote) ...[
              Row(children: [
                Expanded(
                  child: _bigButton(
                    icon: Icons.settings_remote_outlined,
                    title: 'Remote control',
                    sub: 'Override, carbs, bolus sent to Loop',
                    selected: false,
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RemoteScreen())),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _bigButton(
                    icon: Icons.edit_note,
                    title: 'Treatment',
                    sub: 'Log carbs, insulin, notes…',
                    selected: _form,
                    onTap: () => setState(() => _form = !_form),
                  ),
                ),
              ]),
              const SizedBox(height: 16),
            ],
            OutlinedButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BolusCalcScreen())),
              icon: const Icon(Icons.calculate_outlined),
              label: const Text('Bolus calculator'),
            ),
            const SizedBox(height: 14),
            if (_form) ..._formWidgets(context, t, mmol, allowed, d),
          ],
        );
      },
    );
  }

  Widget _bigButton({required IconData icon, required String title, required String sub, required bool selected, required VoidCallback onTap}) {
    return Material(
      color: selected ? kAccent.withValues(alpha: 0.18) : kCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          height: 130,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? kAccent : kBorder, width: selected ? 2 : 1),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 40, color: kAccent),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(sub, textAlign: TextAlign.center, style: const TextStyle(color: kMuted, fontSize: 11)),
          ]),
        ),
      ),
    );
  }

  List<Widget> _formWidgets(BuildContext context, _EventType t, bool mmol, bool allowed, DeviceInfo? d) {
    return [
            if (!allowed)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('Logging treatments is turned off in Settings › Data & general.', style: TextStyle(color: kAmber)),
              ),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (var i = 0; i < _types.length; i++)
                ChoiceChip(label: Text(_types[i].label), selected: _type == i, onSelected: (_) => setState(() => _type = i)),
            ]),
            const SizedBox(height: 16),
            Section(children: [
              if (t.carbs)
                StepRow(
                  label: 'Carbs',
                  value: '$_carbs g',
                  onMinus: () => setState(() => _carbs = (_carbs - 5).clamp(0, 300)),
                  onPlus: () => setState(() => _carbs = (_carbs + 5).clamp(0, 300)),
                ),
              if (t.insulin) ...[
                StepRow(
                  label: 'Insulin',
                  value: '${fmtU(_insulin)} U',
                  onMinus: () => setState(() => _insulin = (_insulin - 0.05).clamp(0.0, 30.0)),
                  onPlus: () => setState(() => _insulin = (_insulin + 0.05).clamp(0.0, 30.0)),
                ),
                Builder(builder: (_) {
                  final c = BolusCalc.now(carbs: t.carbs ? _carbs.toDouble() : 0);
                  if (!c.hasProfile) return const SizedBox.shrink();
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _insulin = c.total),
                      child: Text('Calculator: ${fmtU(c.total)} U (use it)'),
                    ),
                  );
                }),
              ],
              if (t.target) ...[
                StepRow(
                  label: 'Target',
                  value: fmtBg(_target, mmol),
                  onMinus: () => setState(() => _target = (_target - (mmol ? mgPerMmol / 2 : 5)).clamp(72.0, 270.0)),
                  onPlus: () => setState(() => _target = (_target + (mmol ? mgPerMmol / 2 : 5)).clamp(72.0, 270.0)),
                ),
                StepRow(
                  label: 'Duration',
                  value: '$_duration min',
                  onMinus: () => setState(() => _duration = (_duration - 15).clamp(15, 720)),
                  onPlus: () => setState(() => _duration = (_duration + 15).clamp(15, 720)),
                ),
              ],
              if (t.bg)
                StepRow(
                  label: 'Meter reading',
                  value: fmtBg(_bg, mmol),
                  onMinus: () => setState(() => _bg = (_bg - (mmol ? mgPerMmol / 10 : 1)).clamp(20.0, 600.0)),
                  onPlus: () => setState(() => _bg = (_bg + (mmol ? mgPerMmol / 10 : 1)).clamp(20.0, 600.0)),
                ),
              StepRow(
                label: 'When',
                value: _minutesAgo == 0 ? 'Now' : '$_minutesAgo min ago',
                onMinus: () => setState(() => _minutesAgo = (_minutesAgo - 5).clamp(0, 720)),
                onPlus: () => setState(() => _minutesAgo = (_minutesAgo + 5).clamp(0, 720)),
                last: true,
              ),
            ]),
            TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes (optional)')),
            const SizedBox(height: 10),
            Text(
              'IOB ${d?.iob?.toStringAsFixed(2) ?? '–'} U · COB ${d?.cob?.round() ?? '–'} g',
              style: const TextStyle(color: kMuted, fontSize: 13),
            ),
            const SizedBox(height: 18),
            const Text(
              'This records the entry on your site. It does not dose the pump. AAPS may use carbs entered here if it is set to accept them from Nightscout.',
              style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: (_busy || !allowed) ? null : _save,
                child: Text('Save ${t.label.toLowerCase()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
    ];
  }
}
