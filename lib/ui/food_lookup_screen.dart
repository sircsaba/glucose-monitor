import 'dart:async';

import 'package:flutter/material.dart';

import '../data/nightscout.dart';
import '../logic/cnf.dart';
import '../logic/food.dart';
import '../logic/food_lookup.dart';
import 'common.dart';
import 'food_edit_screen.dart';

/// Look a food up by name ("BBQ chicken", "banana", "Cheerios") and get its
/// nutrition filled in: generic foods from the Canadian Nutrient File, and
/// store products from Open Food Facts. The food opens in the food form to
/// check and save.
class FoodLookupScreen extends StatefulWidget {
  final String query;
  final void Function(Food f, [double? amount])? onAddToMeal;
  const FoodLookupScreen({super.key, this.query = '', this.onAddToMeal});
  @override
  State<FoodLookupScreen> createState() => _FoodLookupScreenState();
}

class _FoodLookupScreenState extends State<FoodLookupScreen> {
  late final _q = TextEditingController(text: widget.query);
  Cnf? _cnf;
  List<CnfFood> _generic = [];
  List<OffHit> _products = [];
  bool _productsBusy = false;
  String? _productsError;
  String _productsFor = '';
  Timer? _debounce;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    Cnf.load().then((c) {
      if (!mounted) return;
      setState(() => _cnf = c);
      _searchGeneric();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _searchGeneric();
    _debounce?.cancel();
    if (_tab == 1) _debounce = Timer(const Duration(milliseconds: 700), _searchProducts);
  }

  void _searchGeneric() {
    final c = _cnf;
    if (c == null) return;
    setState(() => _generic = _q.text.trim().length < 2 ? [] : c.search(cnfQuery(_q.text), limit: 40));
  }

  Future<void> _searchProducts() async {
    final q = _q.text.trim();
    if (q.length < 2 || q == _productsFor) return;
    setState(() {
      _productsBusy = true;
      _productsError = null;
    });
    try {
      final r = await searchOff(q);
      if (!mounted || _q.text.trim() != q) return;
      setState(() {
        _products = r;
        _productsFor = q;
      });
    } catch (e) {
      if (mounted) setState(() => _productsError = 'Cannot search the store products right now ($e)');
    }
    if (mounted) setState(() => _productsBusy = false);
  }

  Future<void> _pickGeneric(CnfFood c) async {
    final portions = cnfPortions(c);
    final grams = TextEditingController();
    final p = await showModalBottomSheet<CnfPortion>(
      context: context,
      isScrollControlled: true,
      builder: (s) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(s).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(c.en, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('One portion is…', style: TextStyle(color: kMuted))),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final p in portions)
                  ListTile(
                    title: Text(p.label),
                    subtitle: Text('${fmtAmount(p.grams.roundToDouble())} g · '
                        '${fmtAmount(((c.per100.carbs ?? 0) * p.grams / 100 * 10).round() / 10)} g carbs'),
                    onTap: () => Navigator.pop(s, p),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: grams,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Or my own size', suffixText: 'g'),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () {
                    final g = num_(grams.text);
                    if (g != null && g > 0) Navigator.pop(s, CnfPortion('${fmtAmount(g)} g', g));
                  },
                  child: const Text('Use'),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
    grams.dispose();
    if (p == null || !mounted) return;
    final group = _cnf?.groups[c.group]?.$1 ?? '';
    final f = foodFromCnf(c, p, category: group);
    await _open(f);
  }

  Future<void> _pickProduct(OffHit h) async {
    Food? f;
    try {
      f = await NightscoutClient.lookupBarcode(h.code);
    } catch (e) {
      if (mounted) toast(context, e.toString());
      return;
    }
    if (!mounted) return;
    if (f == null) return toast(context, 'This product has no details in Open Food Facts');
    await _open(f);
  }

  Future<void> _open(Food f) async {
    final saved = await Navigator.push<Food>(
        context, MaterialPageRoute(builder: (_) => FoodEditScreen(food: f, isNew: true, onAddToMeal: widget.onAddToMeal)));
    if (saved != null && mounted) Navigator.pop(context, saved);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Look up a food')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: TextField(
            controller: _q,
            autofocus: widget.query.isEmpty,
            onChanged: _changed,
            onSubmitted: (_) {
              if (_tab == 1) _searchProducts();
            },
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'BBQ chicken, banana, Cheerios…',
              suffixIcon: _q.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _q.clear();
                        _changed('');
                      }),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Generic foods'), icon: Icon(Icons.eco_outlined)),
              ButtonSegment(value: 1, label: Text('Store products'), icon: Icon(Icons.shopping_cart_outlined)),
            ],
            selected: {_tab},
            onSelectionChanged: (v) {
              setState(() => _tab = v.first);
              if (_tab == 1) _searchProducts();
            },
          ),
        ),
        Expanded(child: _tab == 0 ? _genericList() : _productList()),
      ]),
    );
  }

  Widget _note(String t) =>
      Padding(padding: const EdgeInsets.all(24), child: Text(t, textAlign: TextAlign.center, style: const TextStyle(color: kMuted, height: 1.5)));

  Widget _genericList() {
    if (_cnf == null) return const Center(child: CircularProgressIndicator());
    if (_q.text.trim().length < 2) {
      return _note('Type a food: chicken breast, apple, white rice, milk…\n\n'
          'Generic foods come from the Canadian Nutrient File (Health Canada), on the phone: no internet needed. '
          'For a product with a brand, use Store products or scan its barcode.');
    }
    if (_generic.isEmpty) return _note('Nothing found. Try fewer or other words (English or French), or Store products.');
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: _generic.length,
      itemBuilder: (_, i) {
        final c = _generic[i];
        final carbs = c.per100.carbs;
        final kcal = c.per100.energy;
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            title: Text(c.en),
            subtitle: Text('${c.fr}\nPer 100 g: ${carbs == null ? '?' : fmtAmount((carbs * 10).round() / 10)} g carbs'
                '${kcal == null ? '' : ' · ${kcal.round()} kcal'}'),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickGeneric(c),
          ),
        );
      },
    );
  }

  Widget _productList() {
    if (_q.text.trim().length < 2) return _note('Type a product name or a brand. Products come from Open Food Facts (internet needed).');
    if (_productsBusy && _products.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_productsError != null) return _note(_productsError!);
    if (_products.isEmpty) return _note(_productsFor.isEmpty ? 'Searching…' : 'Nothing found. Try the brand name, or scan the barcode.');
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: _products.length,
      itemBuilder: (_, i) {
        final h = _products[i];
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            title: Text(h.name),
            subtitle: Text([
              if (h.brand.isNotEmpty) h.brand,
              if (h.carbs100 != null) '${fmtAmount((h.carbs100! * 10).round() / 10)} g carbs / 100 g',
              if (h.serving.isNotEmpty) 'portion ${h.serving}',
            ].join(' · ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickProduct(h),
          ),
        );
      },
    );
  }
}
