import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../logic/food.dart';
import 'common.dart';
import 'food_edit_screen.dart';

/// A saved recipe: ingredients (with their carbs), the steps to make it, and a
/// cooking mode that keeps the screen on and lets you tick the steps.
class RecipeScreen extends StatefulWidget {
  final Food food;
  const RecipeScreen({super.key, required this.food});
  @override
  State<RecipeScreen> createState() => _RecipeScreenState();
}

class _RecipeScreenState extends State<RecipeScreen> {
  late final Map<String, dynamic> r = widget.food.recipe ?? const {};
  late final double _base = (num_(r['servings']) ?? 1).clamp(0.5, 200).toDouble();
  late double _servings = _base;
  final Set<int> _done = {};
  bool _cooking = false;

  @override
  void dispose() {
    if (_cooking) WakelockPlus.disable();
    super.dispose();
  }

  void _toggleCooking() {
    setState(() => _cooking = !_cooking);
    _cooking ? WakelockPlus.enable() : WakelockPlus.disable();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.food;
    final k = _servings / _base;
    final ings = [for (final i in (r['ingredients'] is List ? r['ingredients'] as List : const [])) if (i is Map) i];
    final steps = [for (final s in (r['steps'] is List ? r['steps'] as List : const [])) s.toString()];
    final perServing = f.n;
    final total = perServing.times(_servings);
    final fs = _cooking ? 19.0 : 15.0;
    return Scaffold(
      appBar: AppBar(
        title: Text(f.name),
        actions: [
          TextButton.icon(
            onPressed: _toggleCooking,
            icon: Icon(_cooking ? Icons.local_fire_department : Icons.soup_kitchen_outlined),
            label: Text(_cooking ? 'Cooking' : 'Cook'),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
        GlutenBanner(f),
        Section(children: [
          StepRow(
            label: 'Servings',
            hint: (r['servingText'] ?? '').toString().isEmpty ? null : 'One serving: ${r['servingText']}',
            value: fmtAmount(_servings),
            onMinus: () => setState(() => _servings = (_servings - (_servings > 2 ? 1 : 0.5)).clamp(0.5, 200)),
            onPlus: () => setState(() => _servings = _servings + (_servings >= 2 ? 1 : 0.5)),
            last: true,
          ),
        ]),
        Text('One serving: ${fmtAmount(((perServing.carbs ?? 0) * 10).round() / 10)} g carbs'
            '${perServing.energy != null ? ' · ${perServing.energy!.round()} kcal' : ''}',
            style: kMono.copyWith(fontSize: 15)),
        Text('All ${fmtAmount(_servings)}: ${(total.carbs ?? 0).round()} g carbs'
            '${total.energy != null ? ' · ${total.energy!.round()} kcal' : ''}',
            style: const TextStyle(color: kMuted, fontSize: 13)),
        if (r['prepMinutes'] != null || r['cookMinutes'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              [
                if (r['prepMinutes'] != null) 'Preparation ${fmtAmount(num_(r['prepMinutes'])!)} min',
                if (r['cookMinutes'] != null) 'Cooking ${fmtAmount(num_(r['cookMinutes'])!)} min',
              ].join(' · '),
              style: const TextStyle(color: kMuted, fontSize: 13),
            ),
          ),
        const SizedBox(height: 16),
        Text('Ingredients${k != 1 ? ' (amounts for ${fmtAmount(_base)}, carbs for ${fmtAmount(_servings)})' : ''}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        for (final i in ings)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (i['gluten'] == 'contains' || i['gluten'] == 'unsure')
                Padding(padding: const EdgeInsets.only(right: 6, top: 2), child: GlutenBadge(i['gluten'] == 'contains' ? Gluten.contains : Gluten.unsure)),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '${i['amount'] ?? ''} ', style: TextStyle(fontWeight: FontWeight.w700, fontSize: fs)),
                  TextSpan(text: '${i['name'] ?? ''}', style: TextStyle(fontSize: fs)),
                  if ((i['note'] ?? '').toString().isNotEmpty)
                    TextSpan(text: '  ${i['note']}', style: TextStyle(color: kMuted, fontSize: fs - 3)),
                ])),
              ),
              if (num_(i['carbs']) != null)
                Text('${fmtAmount(((num_(i['carbs'])! * k) * 10).round() / 10)} g', style: kMono.copyWith(color: kMuted, fontSize: fs - 2)),
            ]),
          ),
        if (ings.isEmpty && f.ingredients.isNotEmpty) Text(f.ingredients, style: TextStyle(fontSize: fs, height: 1.5)),
        const SizedBox(height: 18),
        if (steps.isNotEmpty) ...[
          const Text('How to make it', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (var s = 0; s < steps.length; s++)
            InkWell(
              onTap: () => setState(() => _done.contains(s) ? _done.remove(s) : _done.add(s)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CircleAvatar(
                    radius: _cooking ? 16 : 13,
                    backgroundColor: _done.contains(s) ? kGlutenFree : kAccent.withValues(alpha: 0.25),
                    child: _done.contains(s)
                        ? const Icon(Icons.check, size: 16, color: Colors.black)
                        : Text('${s + 1}', style: TextStyle(fontSize: _cooking ? 15 : 13, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      steps[s],
                      style: TextStyle(
                        fontSize: fs,
                        height: 1.45,
                        color: _done.contains(s) ? kMuted : kText,
                        decoration: _done.contains(s) ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                ]),
              ),
            ),
        ],
        if (f.notes.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(f.notes, style: const TextStyle(color: kMuted, fontSize: 13, height: 1.4)),
        ],
      ]),
    );
  }
}
