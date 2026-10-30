import 'package:flutter/material.dart';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../data/nightscout.dart';
import '../logic/barcode.dart';
import '../logic/food.dart';
import '../logic/ocr.dart';
import '../logic/pdf_text.dart';
import '../logic/recipe_web.dart';
import '../plus.dart';
import '../state/app_state.dart';
import 'bolus_calc_view.dart';
import 'common.dart';
import 'barcode_scan_screen.dart';
import 'food_edit_screen.dart';
import 'food_lookup_screen.dart';
import 'recipe_builder_screen.dart';
import 'meal_plan_screen.dart';
import 'remote_screen.dart';
import 'school_lunch_screen.dart';

/// Foods from the shared food list: search, favorites, meal types, barcode
/// scanning (also in the store), and a meal put together from several foods.
class FoodScreen extends StatefulWidget {
  const FoodScreen({super.key});
  @override
  State<FoodScreen> createState() => _FoodScreenState();
}

class _FoodScreenState extends State<FoodScreen> {
  final _search = TextEditingController();
  String _filter = 'favorites'; // favorites, all, breakfast, lunch, supper, snack
  bool _gfOnly = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Always fetch the list again: foods added on another phone or computer
    // show up (the last list stays on screen meanwhile).
    final first = !app.foodsLoaded;
    app.loadFoods().then((_) {
      if (mounted && first && app.foods.isNotEmpty && !app.foods.any((f) => f.favorite)) setState(() => _filter = 'all');
    });
    app.loadLunches().catchError((_) {});
    final h = DateTime.now().hour;
    // Start on the meal of the time of day when there are no favorites yet.
    if (app.foodsLoaded && !app.foods.any((f) => f.favorite)) {
      _filter = h < 10 ? 'breakfast' : (h < 14 ? 'lunch' : (h < 20 ? 'supper' : 'snack'));
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Food> get _shown {
    final q = _search.text;
    return [
      for (final f in app.foods)
        if (f.matches(q) &&
            (!_gfOnly || f.gluten == Gluten.free) &&
            (q.isNotEmpty || _filter == 'all' || (_filter == 'favorites' ? f.favorite : f.meals.contains(_filter))))
          f
    ];
  }

  // ------------------------------------------------------------ barcode

  Future<void> _scan() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.qr_code_scanner), title: const Text('Scan with the camera'), onTap: () => Navigator.pop(c, 'live')),
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Take a photo of the barcode'), onTap: () => Navigator.pop(c, 'camera')),
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose a photo'), onTap: () => Navigator.pop(c, 'gallery')),
          ListTile(leading: const Icon(Icons.dialpad), title: const Text('Type the numbers'), onTap: () => Navigator.pop(c, 'type')),
        ]),
      ),
    );
    if (how == null || !mounted) return;
    String? code;
    if (how == 'live') {
      code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const BarcodeScanScreen()));
    } else if (how == 'type') {
      code = await _typeBarcode();
    } else {
      try {
        final f = await ImagePicker().pickImage(source: how == 'camera' ? ImageSource.camera : ImageSource.gallery, maxWidth: 2400);
        if (f == null) return;
        setState(() => _busy = true);
        final bytes = await f.readAsBytes();
        code = readBarcode(bytes);
        if (code == null && mounted) {
          setState(() => _busy = false);
          toast(context, 'No barcode found. Hold the phone 15–20 cm away, straight on, with the whole barcode in the picture, or type the numbers.');
          return;
        }
      } catch (e) {
        if (mounted) toast(context, 'Could not open the picture: $e');
        setState(() => _busy = false);
        return;
      }
    }
    if (code == null || code.isEmpty || !mounted) return setState(() => _busy = false);
    await _showBarcode(code);
  }

  Future<String?> _typeBarcode() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Barcode'),
        content: TextField(controller: c, autofocus: true, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: '0 55000 12345 6')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, normalizeBarcode(c.text)), child: const Text('Look up')),
        ],
      ),
    );
  }

  /// New food: look it up by name (nutrition filled in) or type it in.
  Future<void> _newFood() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.manage_search),
            title: const Text('Look up by name'),
            subtitle: const Text('BBQ chicken, banana, a store product… the nutrition is filled in'),
            onTap: () => Navigator.pop(c, 'lookup'),
          ),
          ListTile(leading: const Icon(Icons.qr_code_scanner), title: const Text('Scan a barcode'), onTap: () => Navigator.pop(c, 'scan')),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Enter it myself'), onTap: () => Navigator.pop(c, 'manual')),
        ]),
      ),
    );
    if (!mounted || how == null) return;
    if (how == 'lookup') return _lookup('');
    if (how == 'scan') return _scan();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => FoodEditScreen(food: Food(name: ''), isNew: true, onAddToMeal: _addToMeal)));
  }

  Future<void> _lookup(String q) async {
    final saved = await Navigator.push<Food>(context, MaterialPageRoute(builder: (_) => FoodLookupScreen(query: q, onAddToMeal: _addToMeal)));
    if (saved != null && mounted) {
      setState(() {
        _search.clear();
        _filter = 'all';
      });
    }
  }

  Future<void> _showBarcode(String code) async {
    setState(() => _busy = true);
    final known = app.foodByBarcode(code);
    if (known != null) {
      setState(() => _busy = false);
      await Navigator.push(context, MaterialPageRoute(builder: (_) => FoodEditScreen(food: known, onAddToMeal: _addToMeal)));
      return;
    }
    Food? f;
    try {
      f = await NightscoutClient.lookupBarcode(code);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
    if (!mounted) return;
    setState(() => _busy = false);
    f ??= Food(name: '', barcode: code, source: 'barcode', glutenWhy: ['This product is not in Open Food Facts: check the package']);
    if (f.name.isEmpty) toast(context, 'Not found in Open Food Facts: enter it from the package');
    if (f.gluten == Gluten.unknown && f.name.isEmpty) f.gluten = Gluten.unsure;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => FoodEditScreen(food: f!, isNew: true, onAddToMeal: _addToMeal)));
  }

  // ------------------------------------------------------------ recipes

  /// Photos of a recipe -> text read on the phone -> recipe builder.
  Future<void> _recipeFromPhotos() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Take a photo (one page at a time)'), onTap: () => Navigator.pop(c, 'camera')),
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose photos or screenshots (all pages)'), onTap: () => Navigator.pop(c, 'gallery')),
        ]),
      ),
    );
    if (how == null) return;
    final paths = <String>[];
    try {
      if (how == 'gallery') {
        for (final f in await ImagePicker().pickMultiImage(maxWidth: 3000)) {
          paths.add(f.path);
        }
      } else {
        while (true) {
          final f = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 3000);
          if (f == null) break;
          paths.add(f.path);
          if (!mounted) return;
          final more = await showDialog<bool>(
            context: context,
            builder: (d) => AlertDialog(
              title: Text('${paths.length} page${paths.length > 1 ? 's' : ''}'),
              content: const Text('Another page of this recipe (for example the steps)?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('No, read it')),
                FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Another page')),
              ],
            ),
          );
          if (more != true || paths.length >= 8) break;
        }
      }
    } catch (e) {
      if (mounted) toast(context, 'Could not open the picture: $e');
      return;
    }
    if (paths.isEmpty || !mounted) return;
    setState(() => _busy = true);
    final text = StringBuffer();
    try {
      for (final p in paths) {
        text.writeln(await readTextFromImage(p) ?? '');
      }
    } catch (e) {
      if (mounted) toast(context, 'Could not read the text: $e');
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (text.toString().trim().isEmpty) {
      toast(context, 'No text found. Try a sharper photo, straight on, in good light.');
      return;
    }
    await Navigator.push(context, MaterialPageRoute(builder: (_) => RecipeBuilderScreen(text: text.toString())));
  }

  /// A PDF of a recipe: its text read directly; a scanned PDF read like photos (phone).
  Future<void> _recipeFromPdf() async {
    Uint8List? bytes;
    try {
      final pick = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf'], withData: true);
      final f = pick?.files.firstOrNull;
      bytes = f == null ? null : (f.bytes ?? await f.xFile.readAsBytes());
    } catch (e) {
      if (mounted) toast(context, 'Could not open the file: $e');
      return;
    }
    if (bytes == null || !mounted) return;
    setState(() => _busy = true);
    var text = '';
    try {
      text = pdfText(bytes);
      if (pdfLooksScanned(text)) {
        if (ocrAvailable) {
          if (mounted) toast(context, 'This PDF is made of pictures: reading the pages…');
          text = await readTextFromPdfPages(bytes) ?? '';
        } else {
          text = '';
          if (mounted) toast(context, 'This PDF is made of pictures (a scan). Open it with the phone app: it reads scanned pages.');
        }
      }
    } catch (e) {
      if (mounted) toast(context, 'Could not read this PDF: $e');
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (text.trim().isEmpty) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => RecipeBuilderScreen(text: text)));
  }

  /// A recipe web page: the recipe written in the page for search engines (no AI).
  Future<void> _recipeFromWeb() async {
    final c = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Recipe from a web address'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://www.ricardocuisine.com/…', helperText: 'Copy the address from the browser and paste it here'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Read the recipe')),
        ],
      ),
    );
    c.dispose();
    if (url == null || url.isEmpty || !mounted) return;
    setState(() => _busy = true);
    WebRecipe? r;
    try {
      final html = await NightscoutClient.recipePage(url, via: app.client);
      r = recipeFromHtml(html, url: url);
      if (r == null && mounted) toast(context, 'No recipe found on that page. Copy the recipe text and use "Type or paste a recipe".');
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == null) return;
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => RecipeBuilderScreen(
                text: r!.toText(), sourceUrl: url, servingText: r.servingText, prepMinutes: r.prepMinutes, cookMinutes: r.cookMinutes)));
  }

  // ------------------------------------------------------------ meal

  void _addToMeal(Food f, [double? amount]) {
    final m = app.meal;
    final existing = m.items.where((i) => identical(i.food, f) || (f.id != null && i.food.id == f.id));
    if (existing.isNotEmpty) {
      existing.first.amount += amount ?? f.portion;
    } else {
      m.items.add(MealItem(f, amount ?? f.portion));
    }
    app.mealChanged();
  }

  Future<void> _pickAmount(Food f) async {
    final step = f.unit == 'g' || f.unit == 'ml' ? (f.portion >= 50 ? 10.0 : 5.0) : 0.5;
    var amount = f.portion;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        final n = f.forAmount(amount);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(f.name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700))),
                GlutenBadge(f.gluten),
              ]),
              if (f.portionText.isNotEmpty) Text('Portion: ${f.portionText}', style: const TextStyle(color: kMuted)),
              const SizedBox(height: 10),
              Section(children: [
                StepRow(
                  label: 'How much',
                  value: '${fmtAmount(amount)} ${unitFor(amount, f.unit)}',
                  onMinus: () => set(() => amount = (amount - step).clamp(step, 5000.0)),
                  onPlus: () => set(() => amount = amount + step),
                ),
                StepRow(
                  label: 'Portions',
                  value: f.portion > 0 ? fmtAmount((amount / f.portion * 10).round() / 10) : '–',
                  onMinus: () => set(() => amount = (amount - f.portion / 2).clamp(f.portion / 2, 5000.0)),
                  onPlus: () => set(() => amount = amount + f.portion / 2),
                  last: true,
                ),
              ]),
              Text(_nutLine(n), style: kMono.copyWith(fontSize: 15)),
              const SizedBox(height: 12),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add to the meal')),
            ]),
          ),
        );
      }),
    );
    if (ok == true) _addToMeal(f, amount);
  }

  Future<void> _logMeal() async {
    final m = app.meal;
    final t = <String, dynamic>{
      'eventType': 'Meal Bolus',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'enteredBy': app.settings.str('enteredBy').isEmpty ? 'Monitor Glucose app' : app.settings.str('enteredBy'),
      'carbs': m.carbs.round(),
      'notes': m.describe(),
      'foods': m.toFoodsJson(),
      'nutrition': m.total.toJson(),
    };
    try {
      await app.postTreatment(t);
      if (!mounted) return;
      toast(context, 'Meal saved: ${m.carbs.round()} g carbs');
      m.items.clear();
      app.mealChanged();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  static String _nutLine(Nutrition n) => [
        '${fmtAmount(((n.carbs ?? 0) * 10).round() / 10)} g carbs',
        if (n.energy != null) '${n.energy!.round()} kcal',
        if (n.protein != null) 'protein ${fmtAmount((n.protein! * 10).round() / 10)} g',
        if (n.fat != null) 'fat ${fmtAmount((n.fat! * 10).round() / 10)} g',
        if (n.fiber != null) 'fiber ${fmtAmount((n.fiber! * 10).round() / 10)} g',
      ].join(' · ');

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Food'),
        actions: [
          IconButton(onPressed: _busy ? null : _scan, icon: const Icon(Icons.qr_code_scanner), tooltip: 'Scan a barcode'),
          IconButton(onPressed: _newFood, icon: const Icon(Icons.add), tooltip: 'New food'),
          PopupMenuButton<String>(
            tooltip: 'Recipes',
            icon: const Icon(Icons.menu_book_outlined),
            onSelected: (v) {
              if (v == 'photo') _recipeFromPhotos();
              if (v == 'pdf') _recipeFromPdf();
              if (v == 'web') _recipeFromWeb();
              if (v == 'text') Navigator.push(context, MaterialPageRoute(builder: (_) => const RecipeBuilderScreen()));
              if (v == 'ca' || v == 'us') app.change((x) => x.set('labelFormat', v == 'us' ? 1 : 0));
            },
            itemBuilder: (_) => [
              if (ocrAvailable)
                const PopupMenuItem(value: 'photo', child: ListTile(leading: Icon(Icons.photo_camera_outlined), title: Text('Scan a recipe (photos)'))),
              const PopupMenuItem(value: 'pdf', child: ListTile(leading: Icon(Icons.picture_as_pdf_outlined), title: Text('Recipe from a PDF file'))),
              const PopupMenuItem(value: 'web', child: ListTile(leading: Icon(Icons.link), title: Text('Recipe from a web address'))),
              const PopupMenuItem(value: 'text', child: ListTile(leading: Icon(Icons.edit_note), title: Text('Type or paste a recipe'))),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(value: 'ca', checked: app.settings.integer('labelFormat') != 1, child: const Text('Canadian nutrition label')),
              CheckedPopupMenuItem(value: 'us', checked: app.settings.integer('labelFormat') == 1, child: const Text('US nutrition label')),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final shown = _shown;
          final meal = app.meal;
          return Column(children: [
            if (_busy) const LinearProgressIndicator(),
            if (app.mealPlan != null) const Padding(padding: EdgeInsets.fromLTRB(12, 8, 12, 0), child: MealPlanBanner()),
            _lunchBanner(),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search my foods',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(_search.clear)),
                ),
              ),
            ),
            SizedBox(
              height: 46,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                for (final k in ['favorites', 'all', ...mealTypes])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      avatar: k == 'favorites' ? const Icon(Icons.star, size: 18, color: kAmber) : null,
                      label: Text(k == 'favorites' ? 'Favorites' : (k == 'all' ? 'All' : mealLabels[k]!)),
                      selected: _filter == k,
                      onSelected: (_) => setState(() => _filter = k),
                    ),
                  ),
                FilterChip(label: const Text('Gluten-free only'), selected: _gfOnly, onSelected: (v) => setState(() => _gfOnly = v)),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Icon(Icons.lunch_dining, size: 18),
                  label: const Text('School lunch'),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SchoolLunchScreen())),
                ),
              ]),
            ),
            Expanded(
              child: !app.foodsLoaded && app.foodsError == null
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: app.loadFoods,
                      child: ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), children: [
                        if (app.foodsError != null)
                          Padding(padding: const EdgeInsets.all(8), child: Text(app.foodsError!, style: const TextStyle(color: kAmber))),
                        if (shown.isEmpty && app.foodsError == null)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              app.foods.isEmpty
                                  ? 'No foods yet. Scan a barcode (top right), or tap + to look a food up by name.\n\nFoods are kept in your Nightscout food list, so every phone, tablet and the web app see the same ones.'
                                  : 'Nothing here. Try All, or mark foods as favorites with the star.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: kMuted, height: 1.5),
                            ),
                          ),
                        for (final f in shown) _tile(f),
                        if (_search.text.trim().length >= 2)
                          Card(
                            margin: const EdgeInsets.only(top: 6),
                            child: ListTile(
                              leading: const Icon(Icons.manage_search, color: kAccent),
                              title: Text('Look up “${_search.text.trim()}”'),
                              subtitle: const Text('Generic foods and store products, with the nutrition filled in'),
                              onTap: () => _lookup(_search.text.trim()),
                            ),
                          ),
                      ]),
                    ),
            ),
            if (!meal.isEmpty) _mealPanel(meal),
          ]);
        },
      ),
    );
  }

  /// Today's school lunch, when there is one with food left.
  Widget _lunchBanner() {
    final l = app.lunchToday;
    if (l == null) return const SizedBox.shrink();
    final left = l.waiting;
    final carbs = left.fold(0.0, (a, i) => a + (i.leftNutrition.carbs ?? 0));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: kAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SchoolLunchScreen())),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: kAccent)),
            child: Row(children: [
              const Icon(Icons.lunch_dining, color: kAccent, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('School lunch', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  Text('${left.length} food${left.length > 1 ? 's' : ''} in the box · ${carbs.round()} g carbs',
                      style: const TextStyle(color: kMuted, fontSize: 13)),
                ]),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _tile(Food f) {
    final inMeal = app.meal.items.any((i) => identical(i.food, f));
    return Card(
      color: inMeal ? kAccent.withValues(alpha: 0.12) : kCard,
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 4, right: 8),
        leading: IconButton(
          icon: Icon(f.favorite ? Icons.star : Icons.star_border, color: f.favorite ? kAmber : kMuted),
          tooltip: f.favorite ? 'Remove from favorites' : 'Add to favorites',
          onPressed: () async {
            f.favorite = !f.favorite;
            app.mealChanged();
            try {
              await app.saveFood(f);
            } catch (e) {
              f.favorite = !f.favorite;
              app.mealChanged();
              if (mounted) toast(context, e.toString());
            }
          },
        ),
        title: Row(children: [
          Expanded(child: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
          const SizedBox(width: 6),
          GlutenBadge(f.gluten),
        ]),
        subtitle: Text(
          [
            if (f.brand.isNotEmpty) f.brand,
            '${fmtAmount(f.carbs)} g carbs / ${fmtAmount(f.portion)} ${unitFor(f.portion, f.unit)}',
            if (f.n.energy != null) '${f.n.energy!.round()} kcal',
            if (f.meals.isNotEmpty) f.meals.map((m) => mealLabels[m]).join(', '),
          ].join(' · '),
          style: const TextStyle(color: kMuted, fontSize: 12.5),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'Details',
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FoodEditScreen(food: f, onAddToMeal: _addToMeal))),
        ),
        onTap: () => _pickAmount(f),
      ),
    );
  }

  Widget _mealPanel(Meal meal) {
    final t = meal.total;
    return Container(
      decoration: const BoxDecoration(color: kCard, border: Border(top: BorderSide(color: kBorder))),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Text('Meal', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            GlutenBadge(meal.gluten),
            const Spacer(),
            Text('${(t.carbs ?? 0).round()} g carbs', style: kMono.copyWith(fontSize: 18, fontWeight: FontWeight.w700, color: kAccent)),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Clear the meal',
              onPressed: () {
                meal.items.clear();
                app.mealChanged();
              },
            ),
          ]),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: ListView(shrinkWrap: true, children: [
              for (final i in meal.items)
                Row(children: [
                  Expanded(child: Text('${i.food.name}  ${fmtAmount(i.amount)} ${unitFor(i.amount, i.food.unit)}', overflow: TextOverflow.ellipsis)),
                  Text('${fmtAmount(((i.n.carbs ?? 0) * 10).round() / 10)} g', style: kMono.copyWith(color: kMuted)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                    tooltip: 'Remove',
                    onPressed: () {
                      meal.items.remove(i);
                      app.mealChanged();
                    },
                  ),
                ]),
            ]),
          ),
          Text(_nutLine(t), style: const TextStyle(color: kMuted, fontSize: 12.5)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BolusCalcScreen(carbs: meal.carbs))),
                icon: const Icon(Icons.calculate_outlined),
                label: const Text('Calculator'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => MealPlanScreen(carbs: meal.carbs, note: meal.describe(), foods: meal.toFoodsJson()))),
                icon: const Icon(Icons.alarm),
                label: const Text('Prebolus / timer'),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          SizedBox(
            height: 46,
            child: kRemote
                ? FilledButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RemoteScreen(carbs: meal.carbs, mealNote: meal.describe()))),
                    icon: const Icon(Icons.send),
                    label: const Text('Send carbs and bolus to Loop now'),
                  )
                : FilledButton.icon(
                    onPressed: app.settings.flag('allowTreatments') ? _logMeal : null,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Log the meal'),
                  ),
          ),
        ]),
      ),
    );
  }
}
