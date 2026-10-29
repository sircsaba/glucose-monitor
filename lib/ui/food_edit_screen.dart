import 'package:flutter/material.dart';

import '../logic/food.dart';
import '../state/app_state.dart';
import 'common.dart';

const kGlutenFree = Color(0xFF3DBE7A);
const kGlutenBad = Color(0xFFFF4D5A);
const kGlutenUnsure = Color(0xFFF2C94C);

Color glutenColor(Gluten g) => switch (g) {
      Gluten.free => kGlutenFree,
      Gluten.contains => kGlutenBad,
      Gluten.unsure => kGlutenUnsure,
      Gluten.unknown => kMuted,
    };

String glutenText(Gluten g) => switch (g) {
      Gluten.free => 'Gluten-free',
      Gluten.contains => 'Contains gluten',
      Gluten.unsure => 'Check the package',
      Gluten.unknown => 'Gluten not checked',
    };

String glutenShort(Gluten g) => switch (g) {
      Gluten.free => 'GF',
      Gluten.contains => 'Gluten',
      Gluten.unsure => 'Check',
      Gluten.unknown => '?',
    };

/// Small coloured label for lists.
class GlutenBadge extends StatelessWidget {
  final Gluten g;
  const GlutenBadge(this.g, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = glutenColor(g);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(8), border: Border.all(color: c)),
      child: Text(glutenShort(g), style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

/// Big verdict box (barcode results, food page).
class GlutenBanner extends StatelessWidget {
  final Food f;
  const GlutenBanner(this.f, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = glutenColor(f.gluten);
    final icon = switch (f.gluten) {
      Gluten.free => Icons.check_circle,
      Gluten.contains => Icons.cancel,
      Gluten.unsure => Icons.help,
      Gluten.unknown => Icons.help_outline,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14), border: Border.all(color: c, width: 2)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: c, size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(glutenText(f.gluten), style: TextStyle(color: c, fontSize: 22, fontWeight: FontWeight.w800)),
            for (final w in f.glutenWhy) Text(w, style: const TextStyle(fontSize: 13.5, height: 1.4)),
            if (f.source == 'barcode')
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('From Open Food Facts. Recipes change: when in doubt, read the package.',
                    style: TextStyle(color: kMuted, fontSize: 11.5)),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Add or change a food. [isNew]: from a barcode or the + button (not saved yet).
class FoodEditScreen extends StatefulWidget {
  final Food food;
  final bool isNew;
  /// Called with the saved food when the user taps "Save and add to meal".
  final void Function(Food f)? onAddToMeal;
  const FoodEditScreen({super.key, required this.food, this.isNew = false, this.onAddToMeal});
  @override
  State<FoodEditScreen> createState() => _FoodEditScreenState();
}

class _FoodEditScreenState extends State<FoodEditScreen> {
  late final Food f = widget.isNew ? widget.food : widget.food.copy();
  late final _name = TextEditingController(text: f.name);
  late final _brand = TextEditingController(text: f.brand);
  late final _category = TextEditingController(text: f.category);
  late final _portionText = TextEditingController(text: f.portionText);
  late final _ingredients = TextEditingController(text: f.ingredients);
  late final _allergens = TextEditingController(text: f.allergens);
  late final _notes = TextEditingController(text: f.notes);
  late final _barcode = TextEditingController(text: f.barcode);
  late final _portion = TextEditingController(text: fmtAmount(f.portion));
  late final Map<String, TextEditingController> _nut = {
    'carbs': TextEditingController(text: _v(f.n.carbs)),
    'energy': TextEditingController(text: _v(f.n.energy)),
    'protein': TextEditingController(text: _v(f.n.protein)),
    'fat': TextEditingController(text: _v(f.n.fat)),
    'fiber': TextEditingController(text: _v(f.n.fiber)),
    'sugars': TextEditingController(text: _v(f.n.sugars)),
    'sodium': TextEditingController(text: _v(f.n.sodium)),
  };
  bool _busy = false;

  static String _v(double? x) => x == null ? '' : fmtAmount((x * 10).round() / 10);

  @override
  void dispose() {
    for (final c in [_name, _brand, _category, _portionText, _ingredients, _allergens, _notes, _barcode, _portion, ..._nut.values]) {
      c.dispose();
    }
    super.dispose();
  }

  /// New portion size typed: recompute the nutrition from the per-100 data.
  void _portionChanged(String s) {
    final v = num_(s);
    if (v == null || v <= 0) return;
    if ((f.unit == 'g' || f.unit == 'ml') && f.per100.carbs != null) {
      setState(() {
        f.setPortion(v);
        _nut['carbs']!.text = _v(f.n.carbs);
        _nut['energy']!.text = _v(f.n.energy);
        _nut['protein']!.text = _v(f.n.protein);
        _nut['fat']!.text = _v(f.n.fat);
        _nut['fiber']!.text = _v(f.n.fiber);
        _nut['sugars']!.text = _v(f.n.sugars);
        _nut['sodium']!.text = _v(f.n.sodium);
      });
    }
  }

  void _collect() {
    f.name = _name.text.trim();
    f.brand = _brand.text.trim();
    f.category = _category.text.trim();
    f.portionText = _portionText.text.trim();
    f.ingredients = _ingredients.text.trim();
    f.allergens = _allergens.text.trim();
    f.notes = _notes.text.trim();
    f.barcode = _barcode.text.trim();
    f.portion = num_(_portion.text) ?? f.portion;
    f.n = Nutrition(
      carbs: num_(_nut['carbs']!.text),
      energy: num_(_nut['energy']!.text),
      protein: num_(_nut['protein']!.text),
      fat: num_(_nut['fat']!.text),
      fiber: num_(_nut['fiber']!.text),
      sugars: num_(_nut['sugars']!.text),
      sodium: num_(_nut['sodium']!.text),
    );
  }

  Future<void> _save({bool addToMeal = false}) async {
    _collect();
    if (f.name.isEmpty) return toast(context, 'Give the food a name');
    if (f.n.carbs == null) return toast(context, 'Enter the carbs of one portion (0 if none)');
    setState(() => _busy = true);
    try {
      final saved = await app.saveFood(f);
      if (!mounted) return;
      if (addToMeal) widget.onAddToMeal?.call(saved);
      Navigator.pop(context, saved);
      toast(context, '${saved.name} saved');
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${f.name}?'),
        content: const Text('It is removed from the food list on every device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.deleteFood(widget.food);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  Widget _field(TextEditingController c, String label, {int lines = 1, TextInputType? type, String? hint, ValueChanged<String>? onChanged}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          minLines: 1,
          maxLines: lines,
          keyboardType: type,
          onChanged: onChanged,
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
      );

  Widget _num(String key, String label, String unit) => Expanded(
        child: TextField(
          controller: _nut[key],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, suffixText: unit),
        ),
      );

  @override
  Widget build(BuildContext context) {
    const units = ['g', 'ml', 'piece', 'slice', 'cup', 'tbsp', 'tsp', 'serving'];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'New food' : 'Food'),
        actions: [
          if (!widget.isNew) IconButton(onPressed: _busy ? null : _delete, icon: const Icon(Icons.delete_outline), tooltip: 'Delete'),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
        if (f.source == 'barcode' || f.gluten != Gluten.unknown) GlutenBanner(f),
        _field(_name, 'Name'),
        Row(children: [
          Expanded(child: _field(_brand, 'Brand')),
          const SizedBox(width: 10),
          Expanded(child: _field(_category, 'Category')),
        ]),
        const SizedBox(height: 6),
        const Text('One portion', style: TextStyle(color: kMuted, fontSize: 13)),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          SizedBox(
            width: 90,
            child: TextField(
              controller: _portion,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: _portionChanged,
              decoration: const InputDecoration(labelText: 'Size'),
            ),
          ),
          const SizedBox(width: 10),
          DropdownButton<String>(
            value: units.contains(f.unit) ? f.unit : 'g',
            items: [for (final u in units) DropdownMenuItem(value: u, child: Text(u))],
            onChanged: (u) => setState(() => f.unit = u ?? 'g'),
          ),
          const SizedBox(width: 10),
          Expanded(child: TextField(controller: _portionText, decoration: const InputDecoration(labelText: 'As on the package', hintText: '2 slices (56 g)'))),
        ]),
        const SizedBox(height: 14),
        const Text('Nutrition of one portion', style: TextStyle(color: kMuted, fontSize: 13)),
        Row(children: [_num('carbs', 'Carbs', 'g'), const SizedBox(width: 10), _num('energy', 'Calories', 'kcal')]),
        Row(children: [_num('protein', 'Protein', 'g'), const SizedBox(width: 10), _num('fat', 'Fat', 'g')]),
        Row(children: [_num('fiber', 'Fiber', 'g'), const SizedBox(width: 10), _num('sugars', 'Sugars', 'g')]),
        Row(children: [_num('sodium', 'Sodium', 'mg'), const SizedBox(width: 10), const Expanded(child: SizedBox())]),
        if (f.per100.carbs != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Per 100 ${f.unit == 'ml' ? 'ml' : 'g'}: ${fmtAmount(f.per100.carbs!)} g carbs'
              '${f.per100.energy != null ? ' · ${f.per100.energy!.round()} kcal' : ''}. Change the size and the values follow.',
              style: const TextStyle(color: kMuted, fontSize: 12),
            ),
          ),
        const SizedBox(height: 18),
        const Text('Gluten', style: TextStyle(color: kMuted, fontSize: 13)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final g in Gluten.values)
            ChoiceChip(
              label: Text(glutenText(g)),
              selected: f.gluten == g,
              selectedColor: glutenColor(g).withValues(alpha: 0.3),
              onSelected: (_) => setState(() {
                if (f.gluten != g) f.glutenWhy = ['Set by hand'];
                f.gluten = g;
              }),
            ),
        ]),
        const SizedBox(height: 18),
        const Text('Eaten at', style: TextStyle(color: kMuted, fontSize: 13)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in mealTypes)
            FilterChip(
              label: Text(mealLabels[m]!),
              selected: f.meals.contains(m),
              onSelected: (on) => setState(() => on ? f.meals.add(m) : f.meals.remove(m)),
            ),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Favorite'),
          value: f.favorite,
          onChanged: (v) => setState(() => f.favorite = v),
        ),
        const SizedBox(height: 6),
        _field(_ingredients, 'Ingredients', lines: 8),
        _field(_allergens, 'Allergens'),
        _field(_barcode, 'Barcode', type: TextInputType.number),
        _field(_notes, 'Notes', lines: 4),
        const SizedBox(height: 10),
        SizedBox(
          height: 52,
          child: FilledButton(
            onPressed: _busy ? null : () => _save(),
            child: Text(widget.isNew ? 'Save to my foods' : 'Save', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
        if (widget.onAddToMeal != null) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: OutlinedButton(onPressed: _busy ? null : () => _save(addToMeal: true), child: const Text('Save and add to the meal')),
          ),
        ],
      ]),
    );
  }
}
