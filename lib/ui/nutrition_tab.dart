import 'package:flutter/material.dart';

import '../logic/food.dart';
import '../logic/glucose.dart';
import '../logic/nutrition_report.dart';
import 'common.dart';

const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String _day(DateTime d) => '${_wd[d.weekday - 1]} ${d.year}-${two(d.month)}-${two(d.day)}';
String _hm(DateTime t) => '${two(t.hour)}:${two(t.minute)}';
String _g(double? v) => v == null ? '–' : v.round().toString();

/// Rows for the screen and the PDF.
List<List<String>> nutritionDayRows(NutritionReport r) => [
      ['Day', 'Carbs g', 'Calories', 'Protein g', 'Fat g', 'Fibre g', 'Sugars g', 'Meals'],
      for (final d in r.days.reversed)
        [
          _day(d.day),
          _g(d.carbs),
          d.mealCount == 0 ? '–' : _g(d.meals.energy),
          d.mealCount == 0 ? '–' : _g(d.meals.protein),
          d.mealCount == 0 ? '–' : _g(d.meals.fat),
          d.mealCount == 0 ? '–' : _g(d.meals.fiber),
          d.mealCount == 0 ? '–' : _g(d.meals.sugars),
          d.mealCount == 0 ? '' : '${d.mealCount}',
        ],
    ];

List<List<String>> mealRiseRows(NutritionReport r, bool mmol, {int limit = 15}) => [
      ['When', 'Meal', 'Carbs', 'Before', 'Peak', 'Rise', 'After'],
      for (final m in r.meals.take(limit))
        [
          '${_day(m.meal.t)} ${_hm(m.meal.t)}',
          m.description + (m.overlap ? ' *' : ''),
          '${m.carbs.round()} g',
          m.startMg == null ? '–' : fmtBg(m.startMg!, mmol),
          m.peakMg == null ? '–' : fmtBg(m.peakMg!, mmol),
          m.rise == null ? '–' : '${m.rise! >= 0 ? '+' : ''}${fmtBg(m.rise!, mmol)}',
          m.minutesToPeak == null ? '–' : '${m.minutesToPeak} min',
        ],
    ];

List<List<String>> foodRiseRows(NutritionReport r, bool mmol) => [
      ['Food', 'Meals', 'Average rise', 'Average carbs'],
      for (final f in r.foods.take(20)) [f.name, '${f.meals}', '+${fmtBg(f.avgRise, mmol)}', '${f.avgCarbs.round()} g'],
    ];

/// The Nutrition tab of Reports.
List<Widget> nutritionTab(NutritionReport r, bool mmol) {
  final avg = r.avgMeals;
  Widget tile(String label, String value, {String? sub}) => Container(
        width: 150,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 12.5)),
          Text(value, style: kMono.copyWith(fontSize: 22, fontWeight: FontWeight.w700)),
          if (sub != null) Text(sub, style: const TextStyle(color: kMuted, fontSize: 11)),
        ]),
      );
  Widget table(List<List<String>> rows, {Set<int> left = const {0}}) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 34,
          dataRowMinHeight: 30,
          dataRowMaxHeight: 52,
          columnSpacing: 16,
          horizontalMargin: 8,
          columns: [
            for (var i = 0; i < rows.first.length; i++)
              DataColumn(label: Text(rows.first[i], style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)), numeric: !left.contains(i)),
          ],
          rows: [
            for (final row in rows.skip(1))
              DataRow(cells: [
                for (var i = 0; i < row.length; i++)
                  DataCell(ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: i == 1 && left.contains(1) ? 260 : 170),
                    child: Text(row[i], style: const TextStyle(fontSize: 12.5)),
                  )),
              ]),
          ],
        ),
      );

  return [
    Wrap(spacing: 10, runSpacing: 10, children: [
      tile('Carbs per day', '${r.avgCarbs.round()} g', sub: 'all carb entries'),
      tile('Calories per day', avg.energy == null ? '–' : '${avg.energy!.round()}', sub: 'days with meals from Food'),
      tile('Protein per day', avg.protein == null ? '–' : '${avg.protein!.round()} g'),
      tile('Fat per day', avg.fat == null ? '–' : '${avg.fat!.round()} g'),
    ]),
    const SizedBox(height: 8),
    Text(
      'Carbs come from every carb entry (Loop and the apps). Calories, protein and fat come from meals put together on the Food screen: '
      '${r.daysWithMeals} of ${r.days.length} days have some.',
      style: const TextStyle(color: kMuted, fontSize: 12.5, height: 1.4),
    ),
    const SizedBox(height: 18),
    const Text('Day by day', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
    table(nutritionDayRows(r)),
    const SizedBox(height: 20),
    const Text('Meals that raised glucose the most', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
    const Text('From the reading when eating to the highest in the next 3 hours. * another meal or carbs within 2 hours.',
        style: TextStyle(color: kMuted, fontSize: 12.5)),
    if (r.meals.isEmpty)
      const Padding(padding: EdgeInsets.all(12), child: Text('No meals from the Food screen in this period yet.', style: TextStyle(color: kMuted)))
    else
      table(mealRiseRows(r, mmol), left: const {0, 1}),
    if (r.foods.isNotEmpty) ...[
      const SizedBox(height: 20),
      const Text('Foods by average rise', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      const Text('Foods eaten in at least 2 meals (meals with other carbs soon after are left out).', style: TextStyle(color: kMuted, fontSize: 12.5)),
      table(foodRiseRows(r, mmol)),
    ],
  ];
}

/// Nutrition of the period, unused fields hidden (for other screens).
String nutritionLine(Nutrition n) => [
      if (n.carbs != null) '${n.carbs!.round()} g carbs',
      if (n.energy != null) '${n.energy!.round()} kcal',
      if (n.protein != null) '${n.protein!.round()} g protein',
      if (n.fat != null) '${n.fat!.round()} g fat',
    ].join(' · ');
