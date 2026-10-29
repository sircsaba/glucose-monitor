import 'package:flutter/material.dart';

import '../logic/cnf.dart';
import '../logic/food.dart';
import '../logic/recipe_parse.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'food_edit_screen.dart';
import 'nutrition_label.dart';

/// Builds a recipe from its text (read from a photo on the phone, or pasted):
/// each ingredient is matched to the Canadian Nutrient File or to one of your
/// own foods, its weight worked out, and the nutrition of one serving shown as
/// a package label. Everything can be changed before saving. No AI.
class RecipeBuilderScreen extends StatefulWidget {
  final String text;
  final Food? existing; // a saved recipe to change
  final String sourceUrl; // the web page it came from
  final String servingText; // "muffin", from the page
  final int? prepMinutes, cookMinutes;
  const RecipeBuilderScreen({super.key, this.text = '', this.existing, this.sourceUrl = '', this.servingText = '', this.prepMinutes, this.cookMinutes});
  @override
  State<RecipeBuilderScreen> createState() => _RecipeBuilderScreenState();
}

class _RecipeBuilderScreenState extends State<RecipeBuilderScreen> {
  Cnf? _cnf;
  final _title = TextEditingController();
  final _serving = TextEditingController(text: '1 serving');
  final _steps = TextEditingController();
  final _paste = TextEditingController();
  double _servings = 4;
  final List<RecipeIngredient> _ing = [];
  final Set<String> _meals = {};
  bool _favorite = false;
  bool _busy = false;
  late final String _sourceUrl = widget.sourceUrl.isNotEmpty ? widget.sourceUrl : (widget.existing?.recipe?['sourceUrl'] ?? '').toString();
  late final int? _prep = widget.prepMinutes ?? num_(widget.existing?.recipe?['prepMinutes'])?.toInt();
  late final int? _cook = widget.cookMinutes ?? num_(widget.existing?.recipe?['cookMinutes'])?.toInt();

  @override
  void initState() {
    super.initState();
    Cnf.load().then((c) {
      if (!mounted) return;
      setState(() => _cnf = c);
      final e = widget.existing;
      if (e != null) {
        _loadExisting(e);
      } else if (widget.text.trim().isNotEmpty) {
        _read(widget.text);
        if (widget.servingText.isNotEmpty) _serving.text = '1 ${widget.servingText}';
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_title, _serving, _steps, _paste]) {
      c.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------ reading

  void _read(String text) {
    final r = splitRecipe(text);
    setState(() {
      if (_title.text.isEmpty) _title.text = r.title;
      if (r.servings != null) _servings = r.servings!;
      for (final l in r.ingredients) {
        _ing.add(_match(l));
      }
      if (r.steps.isNotEmpty) _steps.text = [if (_steps.text.trim().isNotEmpty) _steps.text.trim(), ...r.steps].join('\n');
    });
  }

  RecipeIngredient _match(String line) {
    final p = parseIngredient(line);
    // One of your own foods with this name first (e.g. a gluten-free flour blend you scanned).
    Food? mine;
    final low = p.name.toLowerCase();
    if (low.length >= 3) {
      for (final f in app.foods) {
        final n = f.name.toLowerCase();
        if (n == low || (n.length > 4 && (low.contains(n) || n.contains(low)))) {
          mine = f;
          break;
        }
      }
    }
    final cnf = mine == null && p.name.isNotEmpty ? _cnf?.search(p.name, limit: 1).firstOrNull : null;
    final ing = RecipeIngredient(line, p, cnf: cnf, myFood: mine);
    _weigh(ing);
    ing.gluten = ingredientGluten(p.name, matched: cnf?.en ?? '', myFood: mine);
    return ing;
  }

  void _weigh(RecipeIngredient i) {
    final p = i.parsed;
    if (i.myFood != null) {
      final f = i.myFood!;
      if (p.unit == 'g' || p.unit == 'ml') {
        i.grams = p.qty;
        i.gramsGuessed = p.unit == 'ml';
      } else if (p.qty != null) {
        // "2 bars" of a food whose portion is one bar of 35 g
        i.grams = (f.unit == 'g' || f.unit == 'ml') ? p.qty! * f.portion : null;
        i.gramsGuessed = true;
      }
      return;
    }
    final (g, guessed) = gramsFor(p, i.cnf);
    i.grams = g;
    i.gramsGuessed = guessed;
  }

  void _loadExisting(Food e) {
    final r = e.recipe ?? const {};
    _title.text = e.name;
    _servings = (num_(r['servings']) ?? 1).toDouble();
    _serving.text = (r['servingText'] ?? e.portionText).toString().replaceAll(RegExp(r'\s*\(\d+ g\)$'), '');
    _steps.text = [for (final s in (r['steps'] is List ? r['steps'] as List : const [])) s.toString()].join('\n');
    _meals.addAll(e.meals);
    _favorite = e.favorite;
    for (final j in (r['ingredients'] is List ? r['ingredients'] as List : const [])) {
      if (j is! Map) continue;
      final line = (j['amount'] ?? j['name'] ?? '').toString();
      final ing = RecipeIngredient(line, parseIngredient(line));
      final cid = num_(j['cnf'])?.toInt();
      if (cid != null) ing.cnf = _cnf?.byId[cid];
      final fid = j['foodId']?.toString();
      if (fid != null) ing.myFood = app.foods.where((f) => f.id == fid).firstOrNull;
      ing.grams = num_(j['grams']);
      ing.gluten = Gluten.values.firstWhere((g) => g.name == j['gluten'], orElse: () => ingredientGluten(ing.parsed.name));
      if (ing.cnf == null && ing.myFood == null && ing.grams == null) {
        _ing.add(_match(line));
      } else {
        _ing.add(ing);
      }
    }
    setState(() {});
  }

  // ------------------------------------------------------------ totals

  Nutrition get _total => _ing.fold(Nutrition.empty, (a, i) => a + i.n);
  double get _grams => _ing.fold(0.0, (a, i) => a + (i.grams ?? 0));
  Nutrition get _perServing => _total.times(1 / (_servings <= 0 ? 1 : _servings));
  double? get _servingGrams => _grams > 0 ? _grams / _servings : null;

  String _servingText() {
    final g = _servingGrams;
    final t = _serving.text.trim().isEmpty ? '1 serving' : _serving.text.trim();
    return g == null ? t : '$t (${g.round()} g)';
  }

  // ------------------------------------------------------------ change one

  Future<void> _choose(RecipeIngredient i) async {
    final q = TextEditingController(text: i.parsed.name);
    final picked = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        final mine = [for (final f in app.foods) if (q.text.trim().length >= 2 && f.matches(q.text)) f].take(8).toList();
        final found = _cnf?.search(q.text, limit: 25) ?? const <CnfFood>[];
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(c).size.height * 0.75,
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(controller: q, autofocus: true, onChanged: (_) => set(() {}), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Ingredient (English or French)')),
                ),
                Expanded(
                  child: ListView(children: [
                    if (mine.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 4), child: Text('MY FOODS', style: TextStyle(color: kMuted, fontSize: 12))),
                    for (final f in mine)
                      ListTile(
                        dense: true,
                        leading: GlutenBadge(f.gluten),
                        title: Text(f.name),
                        subtitle: Text('${fmtAmount(f.carbs)} g carbs / ${fmtAmount(f.portion)} ${unitFor(f.portion, f.unit)}'),
                        onTap: () => Navigator.pop(c, f),
                      ),
                    const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text('CANADIAN NUTRIENT FILE', style: TextStyle(color: kMuted, fontSize: 12))),
                    for (final f in found)
                      ListTile(
                        dense: true,
                        title: Text(f.en),
                        subtitle: Text('${f.fr} · ${fmtAmount(((f.per100.carbs ?? 0) * 10).round() / 10)} g carbs / 100 g'),
                        onTap: () => Navigator.pop(c, f),
                      ),
                    ListTile(leading: const Icon(Icons.block), title: const Text('No match (counts as 0)'), onTap: () => Navigator.pop(c, 'none')),
                  ]),
                ),
              ]),
            ),
          ),
        );
      }),
    );
    q.dispose();
    if (picked == null) return;
    setState(() {
      i.myFood = picked is Food ? picked : null;
      i.cnf = picked is CnfFood ? picked : null;
      _weigh(i);
      i.gluten = ingredientGluten(i.parsed.name, matched: i.cnf?.en ?? '', myFood: i.myFood);
    });
  }

  /// Paste many ingredients at once (one per line).
  Future<void> _pasteList() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Paste ingredients'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: c,
            autofocus: true,
            minLines: 6,
            maxLines: 14,
            decoration: const InputDecoration(hintText: '2 cups rice flour\n3 ripe bananas\n1/3 cup maple syrup\n…', helperText: 'One ingredient per line'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Add them')),
        ],
      ),
    );
    c.dispose();
    if (text == null) return;
    final lines = ingredientLines(text);
    if (lines.isEmpty) return;
    setState(() {
      for (final l in lines) {
        _ing.add(_match(l));
      }
    });
    if (mounted) toast(context, '${lines.length} ingredient${lines.length > 1 ? 's' : ''} added');
  }

  Future<void> _editLine(RecipeIngredient? i) async {
    final c = TextEditingController(text: i?.line ?? '');
    final g = TextEditingController(text: i?.grams == null ? '' : fmtAmount((i!.grams! * 10).round() / 10));
    final r = await showDialog<(String, String)>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(i == null ? 'Add an ingredient' : 'Ingredient'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: c,
            autofocus: i == null,
            minLines: 1,
            maxLines: i == null ? 8 : 2,
            decoration: InputDecoration(labelText: 'As in the recipe', hintText: '2 cups rice flour', helperText: i == null ? 'Several? One per line, or paste a list' : null),
          ),
          if (i != null) TextField(controller: g, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Weight', suffixText: 'g')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, (c.text, g.text)), child: const Text('OK')),
        ],
      ),
    );
    c.dispose();
    g.dispose();
    if (r == null || r.$1.trim().isEmpty) return;
    setState(() {
      if (i == null) {
        for (final l in ingredientLines(r.$1)) {
          _ing.add(_match(l));
        }
      } else if (r.$1.trim() != i.line) {
        final idx = _ing.indexOf(i);
        _ing[idx] = _match(r.$1.trim());
      } else {
        final w = num_(r.$2);
        if (w != null) {
          i.grams = w;
          i.gramsGuessed = false;
        }
      }
    });
  }

  // ------------------------------------------------------------ save

  Future<void> _save() async {
    final name = _title.text.trim();
    if (name.isEmpty) return toast(context, 'Give the recipe a name');
    if (_ing.isEmpty) return toast(context, 'Add the ingredients');
    final per = _perServing;
    final sg = _servingGrams;
    final bad = [for (final i in _ing) if (i.gluten == Gluten.contains) i.parsed.name];
    final check = [for (final i in _ing) if (i.gluten == Gluten.unsure || i.gluten == Gluten.unknown) i.parsed.name];
    final gluten = worstGluten(_ing.map((i) => i.gluten));
    final f = widget.existing ?? Food(name: name);
    f
      ..name = name
      ..source = 'recipe'
      ..portion = sg ?? 1
      ..unit = sg == null ? 'serving' : 'g'
      ..portionText = _servingText()
      ..n = per
      ..per100 = sg == null ? Nutrition.empty : per.times(100 / sg)
      ..gluten = gluten
      ..glutenWhy = [
        if (bad.isNotEmpty) 'Contains gluten: ${bad.join(', ')}',
        if (check.isNotEmpty) 'Check these labels: ${check.join(', ')}',
        if (bad.isEmpty && check.isEmpty) 'No gluten in the ingredients',
      ]
      ..ingredients = _ing.map((i) => i.line).join('\n')
      ..meals = _meals.toList()
      ..favorite = _favorite
      ..recipe = {
        'servings': _servings,
        'servingText': _serving.text.trim(),
        if (sg != null) 'servingGrams': (sg * 10).round() / 10,
        'ingredients': [for (final i in _ing) i.toJson()],
        'steps': _steps.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
        'nutritionSource': 'Canadian Nutrient File 2015 (Health Canada)',
        if (_sourceUrl.isNotEmpty) 'sourceUrl': _sourceUrl,
        if (_prep != null) 'prepMinutes': _prep,
        if (_cook != null) 'cookMinutes': _cook,
      };
    setState(() => _busy = true);
    try {
      await app.saveFood(f);
      if (!mounted) return;
      Navigator.pop(context, f);
      toast(context, '$name saved');
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    if (_cnf == null) {
      return Scaffold(appBar: AppBar(title: const Text('Recipe')), body: const Center(child: CircularProgressIndicator()));
    }
    final per = _perServing;
    final us = app.settings.integer('labelFormat') == 1;
    final unmatched = _ing.where((i) => i.grams == null || (i.cnf == null && i.myFood == null)).length;
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'New recipe' : 'Recipe')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
        if (_ing.isEmpty) ...[
          const Text('Paste or type the recipe: ingredients one per line, then the steps.', style: TextStyle(color: kMuted)),
          const SizedBox(height: 8),
          TextField(controller: _paste, minLines: 8, maxLines: 18, decoration: const InputDecoration(hintText: 'Banana muffins\n12 muffins\n\nIngredients\n2 cups rice flour\n3 ripe bananas\n...\n\nDirections\n1. Heat the oven...')),
          const SizedBox(height: 8),
          FilledButton(onPressed: () => _read(_paste.text), child: const Text('Read the recipe')),
          const SizedBox(height: 20),
        ],
        TextField(controller: _title, decoration: const InputDecoration(labelText: 'Recipe name')),
        const SizedBox(height: 10),
        Section(children: [
          StepRow(
            label: 'Makes',
            value: '${fmtAmount(_servings)} servings',
            onMinus: () => setState(() => _servings = (_servings - (_servings > 2 ? 1 : 0.5)).clamp(0.5, 200)),
            onPlus: () => setState(() => _servings = _servings + (_servings >= 2 ? 1 : 0.5)),
            last: true,
          ),
        ]),
        TextField(controller: _serving, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'One serving is', hintText: '1 muffin')),
        const SizedBox(height: 18),
        Row(children: [
          const Expanded(child: Text('Ingredients', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
          TextButton.icon(onPressed: _pasteList, icon: const Icon(Icons.content_paste), label: const Text('Paste list')),
          TextButton.icon(onPressed: () => _editLine(null), icon: const Icon(Icons.add), label: const Text('Add')),
        ]),
        if (unmatched > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('$unmatched ingredient${unmatched > 1 ? 's' : ''} without a match or a weight (in amber): tap to fix.',
                style: const TextStyle(color: kAmber, fontSize: 13)),
          ),
        for (final i in _ing) _ingRow(i),
        const SizedBox(height: 16),
        const Text('How to make it (one step per line)', style: TextStyle(color: kMuted, fontSize: 13)),
        TextField(controller: _steps, minLines: 4, maxLines: 30),
        const SizedBox(height: 18),
        Text('Whole recipe: ${(_total.carbs ?? 0).round()} g carbs · ${_grams.round()} g', style: const TextStyle(color: kMuted)),
        Text('One serving: ${fmtAmount(((per.carbs ?? 0) * 10).round() / 10)} g carbs', style: kMono.copyWith(fontSize: 18, fontWeight: FontWeight.w700, color: kAccent)),
        const SizedBox(height: 12),
        Center(child: NutritionLabel(n: per, servingEn: _servingText(), servingFr: _servingText().replaceFirst('serving', 'portion'), servingsPerContainer: _servings, us: us)),
        const SizedBox(height: 6),
        const Text('Nutrition: Canadian Nutrient File (Health Canada) and your own foods. Estimated from the ingredients.',
            textAlign: TextAlign.center, style: TextStyle(color: kMuted, fontSize: 11.5)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in mealTypes)
            FilterChip(label: Text(mealLabels[m]!), selected: _meals.contains(m), onSelected: (on) => setState(() => on ? _meals.add(m) : _meals.remove(m))),
        ]),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Favorite'), value: _favorite, onChanged: (v) => setState(() => _favorite = v)),
        SizedBox(
          height: 52,
          child: FilledButton(onPressed: _busy ? null : _save, child: const Text('Save the recipe', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
        ),
      ]),
    );
  }

  Widget _ingRow(RecipeIngredient i) {
    final bad = i.grams == null || (i.cnf == null && i.myFood == null);
    final n = i.n;
    return Card(
      color: bad ? kAmber.withValues(alpha: 0.12) : kCard,
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InkWell(onTap: () => _editLine(i), child: Text(i.line, style: const TextStyle(fontWeight: FontWeight.w600))),
              InkWell(
                onTap: () => _choose(i),
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    i.matchName.isEmpty ? 'Tap to choose the food' : '→ ${i.matchName}',
                    style: TextStyle(color: i.matchName.isEmpty ? kAmber : kAccent, fontSize: 12.5),
                  ),
                ),
              ),
              Text(
                [
                  i.grams == null ? 'weight unknown: tap the line' : '${i.gramsGuessed ? '≈ ' : ''}${i.grams!.round()} g',
                  '${fmtAmount(((n.carbs ?? 0) * 10).round() / 10)} g carbs',
                  if (n.energy != null) '${n.energy!.round()} kcal',
                ].join(' · '),
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
            ]),
          ),
          // Tap the badge to change it (gluten-free -> check -> contains).
          InkWell(
            onTap: () => setState(() => i.gluten = switch (i.gluten) {
                  Gluten.free => Gluten.unsure,
                  Gluten.unsure => Gluten.contains,
                  _ => Gluten.free,
                }),
            child: Padding(padding: const EdgeInsets.only(top: 2), child: GlutenBadge(i.gluten)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Remove',
            onPressed: () => setState(() => _ing.remove(i)),
          ),
        ]),
      ),
    );
  }
}
