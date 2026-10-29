import 'package:flutter/material.dart';

import '../logic/food.dart';

/// A nutrition label like on packages: Canada (bilingual "Nutrition Facts /
/// Valeur nutritive") or the United States (FDA "Nutrition Facts"). Values are
/// rounded the way labels round them. Always black on white, like a package.
class NutritionLabel extends StatelessWidget {
  final Nutrition n; // one serving
  final String servingEn; // "1 muffin (60 g)"
  final String servingFr;
  final double? servingsPerContainer;
  final bool us;
  const NutritionLabel({super.key, required this.n, required this.servingEn, String? servingFr, this.servingsPerContainer, this.us = false})
      : servingFr = servingFr ?? servingEn;

  // Daily values used for the % (Canada 2016 regulations; US FDA 2016).
  static const caDv = {'fat': 75.0, 'satTrans': 20.0, 'fiber': 28.0, 'sugars': 100.0, 'sodium': 2300.0, 'potassium': 3400.0, 'calcium': 1300.0, 'iron': 18.0};
  static const usDv = {
    'fat': 78.0, 'satFat': 20.0, 'cholesterol': 300.0, 'sodium': 2300.0, 'carbs': 275.0, 'fiber': 28.0, 'potassium': 4700.0, 'calcium': 1300.0, 'iron': 18.0,
  };

  @override
  Widget build(BuildContext context) => us ? _us() : _ca();

  // ---------------------------------------------------------------- rounding

  static String kcal(double? v) {
    if (v == null) return '–';
    if (v < 5) return '0';
    if (v <= 50) return ((v / 5).round() * 5).toString();
    return ((v / 10).round() * 10).toString();
  }

  /// Grams: under 0.5 -> 0, under 5 -> nearest 0.5, else whole.
  static String grams(double? v) {
    if (v == null) return '–';
    if (v < 0.5) return '0';
    if (v < 5) {
      final h = (v * 2).round() / 2;
      return h == h.roundToDouble() ? h.round().toString() : h.toStringAsFixed(1);
    }
    return v.round().toString();
  }

  /// Sodium, cholesterol...: under 5 -> 0, up to 140 -> nearest 5, else nearest 10.
  static String mg(double? v) {
    if (v == null) return '–';
    if (v < 5) return '0';
    if (v <= 140) return ((v / 5).round() * 5).toString();
    return ((v / 10).round() * 10).toString();
  }

  static String pct(double? v, double dv) {
    if (v == null) return '';
    final p = v / dv * 100;
    if (p < 1) return '0 %';
    if (p <= 10) return '${p.round()} %';
    return '${((p / 2).round() * 2).round()} %';
  }

  // ---------------------------------------------------------------- Canada

  Widget _ca() {
    final satTrans = (n['satFat'] == null && n['transFat'] == null) ? null : (n['satFat'] ?? 0) + (n['transFat'] ?? 0);
    TextStyle b(double s) => TextStyle(color: Colors.black, fontSize: s, fontWeight: FontWeight.w800, height: 1.15);
    TextStyle r(double s) => TextStyle(color: Colors.black, fontSize: s, height: 1.2);
    Widget row(String label, String value, {String p = '', bool bold = true, double indent = 0, bool thick = false}) => Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.black, width: thick ? 3 : 0.8))),
          padding: EdgeInsets.fromLTRB(indent, 2, 0, 2),
          child: Row(children: [
            Expanded(
              child: Text.rich(TextSpan(children: [
                TextSpan(text: label, style: bold ? b(12.5) : r(12.5)),
                TextSpan(text: ' $value', style: r(12.5)),
              ])),
            ),
            Text(p.replaceAll(' %', ' %'), style: b(12.5)),
          ]),
        );
    return _box(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Nutrition Facts', style: b(21)),
      Text('Valeur nutritive', style: b(21)),
      Text('Per $servingEn', style: r(12.5)),
      Text('pour $servingFr', style: r(12.5)),
      const Divider(color: Colors.black, thickness: 1.2, height: 6),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(child: Text.rich(TextSpan(children: [TextSpan(text: 'Calories ', style: b(17)), TextSpan(text: kcal(n.energy), style: b(17))]))),
        Text('% Daily Value*\n% valeur quotidienne*', textAlign: TextAlign.right, style: b(10.5)),
      ]),
      row('Fat / Lipides', '${grams(n.fat)} g', p: pct(n.fat, caDv['fat']!), thick: true),
      row('Saturated / saturés', '${grams(n['satFat'])} g', p: pct(satTrans, caDv['satTrans']!), bold: false, indent: 10),
      row('+ Trans / trans', '${grams(n['transFat'])} g', bold: false, indent: 10),
      row('Carbohydrate / Glucides', '${grams(n.carbs)} g'),
      row('Fibre / Fibres', '${grams(n.fiber)} g', p: pct(n.fiber, caDv['fiber']!), bold: false, indent: 10),
      row('Sugars / Sucres', '${grams(n.sugars)} g', p: pct(n.sugars, caDv['sugars']!), bold: false, indent: 10),
      row('Protein / Protéines', '${grams(n.protein)} g'),
      row('Cholesterol / Cholestérol', '${mg(n['cholesterol'])} mg'),
      row('Sodium', '${mg(n.sodium)} mg', p: pct(n.sodium, caDv['sodium']!)),
      row('Potassium', '${mg(n['potassium'])} mg', p: pct(n['potassium'], caDv['potassium']!), bold: false, thick: true),
      row('Calcium', '${mg(n['calcium'])} mg', p: pct(n['calcium'], caDv['calcium']!), bold: false),
      row('Iron / Fer', '${grams(n['iron'])} mg', p: pct(n['iron'], caDv['iron']!), bold: false),
      const Divider(color: Colors.black, thickness: 1.2, height: 6),
      Text('*5% or less is a little, 15% or more is a lot\n*5 % ou moins c\'est peu, 15 % ou plus c\'est beaucoup', style: r(10)),
    ]));
  }

  // ---------------------------------------------------------------- United States

  Widget _us() {
    TextStyle b(double s) => TextStyle(color: Colors.black, fontSize: s, fontWeight: FontWeight.w800, height: 1.15);
    TextStyle r(double s) => TextStyle(color: Colors.black, fontSize: s, height: 1.2);
    String usPct(double? v, String k) => v == null ? '' : pct(v, usDv[k]!).replaceAll(' %', '%');
    Widget row(String label, String value, {String p = '', bool bold = true, double indent = 0, double line = 0.8}) => Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.black, width: line))),
          padding: EdgeInsets.fromLTRB(indent, 2, 0, 2),
          child: Row(children: [
            Expanded(child: Text.rich(TextSpan(children: [TextSpan(text: label, style: bold ? b(12.5) : r(12.5)), TextSpan(text: ' $value', style: r(12.5))]))),
            Text(p, style: b(12.5)),
          ]),
        );
    return _box(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Nutrition Facts', style: b(26)),
      const Divider(color: Colors.black, thickness: 0.8, height: 4),
      if (servingsPerContainer != null) Text('${_fmtServ(servingsPerContainer!)} servings per container', style: r(13)),
      Row(children: [Expanded(child: Text('Serving size', style: b(14))), Text(servingEn.replaceAll(' g)', 'g)'), style: b(14))]),
      Container(height: 9, color: Colors.black, margin: const EdgeInsets.symmetric(vertical: 2)),
      Text('Amount per serving', style: b(11)),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(child: Text('Calories', style: b(24))),
        Text(kcal(n.energy), style: b(30)),
      ]),
      Container(height: 5, color: Colors.black, margin: const EdgeInsets.only(top: 2)),
      Align(alignment: Alignment.centerRight, child: Text('% Daily Value*', style: b(11))),
      row('Total Fat', '${grams(n.fat).replaceAll(' ', '')}g', p: usPct(n.fat, 'fat')),
      row('Saturated Fat', '${grams(n['satFat'])}g', p: usPct(n['satFat'], 'satFat'), bold: false, indent: 12),
      row('Trans Fat', '${grams(n['transFat'])}g', bold: false, indent: 12),
      row('Cholesterol', '${mg(n['cholesterol'])}mg', p: usPct(n['cholesterol'], 'cholesterol')),
      row('Sodium', '${mg(n.sodium)}mg', p: usPct(n.sodium, 'sodium')),
      row('Total Carbohydrate', '${grams(n.carbs)}g', p: usPct(n.carbs, 'carbs')),
      row('Dietary Fiber', '${grams(n.fiber)}g', p: usPct(n.fiber, 'fiber'), bold: false, indent: 12),
      row('Total Sugars', '${grams(n.sugars)}g', bold: false, indent: 12),
      row('Protein', '${grams(n.protein)}g'),
      Container(height: 9, color: Colors.black, margin: const EdgeInsets.only(top: 2)),
      row('Calcium', '${mg(n['calcium'])}mg', p: usPct(n['calcium'], 'calcium'), bold: false, line: 0),
      row('Iron', '${grams(n['iron'])}mg', p: usPct(n['iron'], 'iron'), bold: false),
      row('Potassium', '${mg(n['potassium'])}mg', p: usPct(n['potassium'], 'potassium'), bold: false),
      Container(height: 5, color: Colors.black, margin: const EdgeInsets.only(top: 2, bottom: 3)),
      Text('* The % Daily Value (DV) tells you how much a nutrient in a serving of food contributes to a daily diet. '
          '2,000 calories a day is used for general nutrition advice.', style: r(9.5)),
    ]));
  }

  static String _fmtServ(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  Widget _box(Widget child) => Container(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.black, width: 1.5)),
        child: DefaultTextStyle(style: const TextStyle(color: Colors.black), child: child),
      );
}
