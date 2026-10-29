import 'package:flutter/material.dart';

import '../logic/food.dart';
import '../logic/glucose.dart';
import '../logic/school_lunch.dart';
import '../plus.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'food_edit_screen.dart';
import 'food_lookup_screen.dart';
import 'remote_screen.dart';

/// School lunch: what was packed at home for a day. At school, tick what is
/// eaten now (all, or part of it) and send it to Loop (or log it). Sent foods
/// move to "Eaten" and cannot be picked again; the rest stays for later.
class SchoolLunchScreen extends StatefulWidget {
  final String? day;
  const SchoolLunchScreen({super.key, this.day});
  @override
  State<SchoolLunchScreen> createState() => _SchoolLunchScreenState();
}

class _SchoolLunchScreenState extends State<SchoolLunchScreen> {
  late String _day = widget.day ?? SchoolLunch.dayKey(DateTime.now());
  final Map<String, double> _pick = {}; // item key -> part of what is left (1, 0.75, 0.5, 0.25)
  bool _edit = false;
  bool _busy = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await app.loadLunches();
      if (!app.foodsLoaded) await app.loadFoods();
    } catch (e) {
      _error = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      final l = app.lunchFor(_day);
      if (l == null || l.isEmpty) _edit = true;
    });
  }

  SchoolLunch get _lunch => app.lunchFor(_day) ?? SchoolLunch(_day);

  bool get _today => _day == SchoolLunch.dayKey(DateTime.now());

  String _dayLabel(String key) {
    final d = SchoolLunch.dayOf(key)!;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final name = diff == 0 ? 'Today' : (diff == 1 ? 'Tomorrow' : (diff == -1 ? 'Yesterday' : days[d.weekday - 1]));
    return '$name ${d.day} ${months[d.month - 1]}';
  }

  /// The next school day (Monday after a Friday).
  String get _nextSchoolDay {
    var d = DateTime.now().add(const Duration(days: 1));
    while (d.weekday > 5) {
      d = d.add(const Duration(days: 1));
    }
    return SchoolLunch.dayKey(d);
  }

  Future<void> _change(void Function(SchoolLunch l) f, {String? done}) async {
    setState(() => _busy = true);
    try {
      await app.changeLunch(_day, f);
      if (done != null && mounted) toast(context, done);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  // ------------------------------------------------------------ packing

  Future<double?> _askAmount(Food f, {double? start}) async {
    var a = start ?? (f.portion > 0 ? f.portion : 1);
    final step = (f.unit == 'g' || f.unit == 'ml') ? (a >= 100 ? 25.0 : 5.0) : 0.5;
    return showDialog<double>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, set) {
        final carbs = f.forAmount(a).carbs ?? 0;
        return AlertDialog(
          title: Text(f.name),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            StepRow(
              label: 'In the lunch box',
              value: '${fmtAmount(a)} ${unitFor(a, f.unit)}',
              onMinus: () => set(() => a = (a - step).clamp(step, 5000)),
              onPlus: () => set(() => a = a + step),
              last: true,
            ),
            Text('${fmtAmount((carbs * 10).round() / 10)} g carbs', style: kMono.copyWith(color: kAccent, fontSize: 16)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(d, a), child: const Text('OK')),
          ],
        );
      }),
    );
  }

  Future<void> _addFromMyFoods() async {
    final q = TextEditingController();
    final f = await showModalBottomSheet<Food>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        final list = [for (final f in app.foods) if (f.matches(q.text)) f];
        list.sort((a, b) => (b.favorite ? 1 : 0) - (a.favorite ? 1 : 0));
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(c).size.height * 0.75,
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: q,
                    autofocus: true,
                    onChanged: (_) => set(() {}),
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'My foods'),
                  ),
                ),
                Expanded(
                  child: list.isEmpty
                      ? const Center(child: Text('No food with that name: use "Look up a food".', style: TextStyle(color: kMuted)))
                      : ListView(children: [
                          for (final f in list)
                            ListTile(
                              leading: GlutenBadge(f.gluten),
                              title: Text(f.name),
                              subtitle: Text('${fmtAmount(f.carbs)} g carbs / ${fmtAmount(f.portion)} ${unitFor(f.portion, f.unit)}'),
                              trailing: f.favorite ? const Icon(Icons.star, color: kAmber, size: 18) : null,
                              onTap: () => Navigator.pop(c, f),
                            ),
                        ]),
                ),
              ]),
            ),
          ),
        );
      }),
    );
    q.dispose();
    if (f != null) await _addFood(f);
  }

  Future<void> _addFood(Food f) async {
    final a = await _askAmount(f);
    if (a == null) return;
    await _change((l) => l.add(f, a));
  }

  Future<void> _lookup() async {
    final saved = await Navigator.push<Food>(context, MaterialPageRoute(builder: (_) => const FoodLookupScreen()));
    if (saved != null && mounted) await _addFood(saved);
  }

  Future<void> _copyFrom() async {
    final days = [for (final l in app.lunches.values) if (l.date != _day && l.items.isNotEmpty) l.date]..sort((a, b) => b.compareTo(a));
    if (days.isEmpty) return toast(context, 'No other lunch to copy');
    final from = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('Same lunch as…', style: TextStyle(fontWeight: FontWeight.w600))),
          for (final d in days.take(14))
            ListTile(
              title: Text(_dayLabel(d)),
              subtitle: Text(app.lunchFor(d)!.items.map((i) => i.food.name).join(', '), maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(c, d),
            ),
        ]),
      ),
    );
    if (from == null) return;
    final src = app.lunchFor(from)!;
    await _change((l) {
      for (final i in src.items) {
        l.add(i.food, i.amount);
      }
    }, done: 'Copied');
  }

  // ------------------------------------------------------------ eating

  Map<String, double> get _amounts {
    final out = <String, double>{};
    for (final i in _lunch.waiting) {
      final part = _pick[i.key];
      if (part != null) out[i.key] = i.left * part;
    }
    return out;
  }

  Meal _mealOf(Map<String, double> amounts) {
    final m = Meal();
    for (final i in _lunch.items) {
      final a = amounts[i.key];
      if (a != null && a > 0) m.items.add(MealItem(i.food, a));
    }
    return m;
  }

  Future<void> _send() async {
    final amounts = _amounts;
    final m = _mealOf(amounts);
    if (m.isEmpty) return;
    if (!app.meal.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Replace the meal?'),
          content: Text('The meal in Food (${app.meal.carbs.round()} g carbs) is replaced by these lunch foods.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Replace')),
          ],
        ),
      );
      if (ok != true) return;
    }
    app.meal.items
      ..clear()
      ..addAll(m.items);
    app.mealChanged();
    final note = 'School lunch: ${m.describe()}';
    var sent = false;
    var how = 'loop';
    if (kRemote) {
      if (!mounted) return;
      await Navigator.push(
          context, MaterialPageRoute(builder: (_) => RemoteScreen(carbs: m.carbs, mealNote: note, onSent: (carbs) => sent = sent || carbs)));
    } else {
      if (!app.settings.flag('allowTreatments')) {
        if (mounted) toast(context, 'Logging treatments is turned off in Settings');
        return;
      }
      how = 'logged';
      setState(() => _busy = true);
      try {
        await app.postTreatment({
          'eventType': 'Meal Bolus',
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'enteredBy': app.settings.str('enteredBy').isEmpty ? 'Monitor Glucose app' : app.settings.str('enteredBy'),
          'carbs': m.carbs.round(),
          'notes': note,
          'foods': m.toFoodsJson(),
          'nutrition': m.total.toJson(),
        });
        sent = true;
        app.meal.items.clear();
        app.mealChanged();
      } catch (e) {
        if (mounted) toast(context, e.toString());
      }
      if (mounted) setState(() => _busy = false);
    }
    if (!sent || !mounted) return;
    // Sent: off the list, into "Eaten". Try again if the site is not answering.
    while (mounted) {
      setState(() => _busy = true);
      try {
        await app.changeLunch(_day, (l) => l.markEaten(amounts, how: how));
        if (mounted) {
          setState(() {
            _pick.clear();
            _busy = false;
          });
          toast(context, 'Eaten: ${m.carbs.round()} g carbs');
        }
        return;
      } catch (e) {
        if (!mounted) return;
        setState(() => _busy = false);
        final again = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('Sent, but the lunch list was not updated'),
            content: Text('$e\n\nTry again, or these foods stay in the lunch box list.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Leave it')),
              FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Try again')),
            ],
          ),
        );
        if (again != true) return;
      }
    }
  }

  // ------------------------------------------------------------ view

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final l = _lunch;
        final waiting = l.waiting;
        final amounts = _amounts;
        final meal = _mealOf(amounts);
        final h24 = app.settings.flag('time24');
        return Scaffold(
          appBar: AppBar(
            title: const Text('School lunch'),
            actions: [
              IconButton(
                tooltip: _edit ? 'Done' : 'Change the lunch box',
                icon: Icon(_edit ? Icons.check : Icons.edit_outlined),
                onPressed: () => setState(() {
                  _edit = !_edit;
                  _pick.clear();
                }),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'copy') _copyFrom();
                  if (v == 'delete') {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (d) => AlertDialog(
                        title: Text('Delete the lunch of ${_dayLabel(_day)}?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      try {
                        await app.deleteLunch(_day);
                      } catch (e) {
                        if (context.mounted) toast(context, e.toString());
                      }
                    }
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'copy', child: ListTile(leading: Icon(Icons.copy_all), title: Text('Same as another day'))),
                  PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete this lunch'))),
                ],
              ),
            ],
          ),
          body: Column(children: [
            if (_busy || _loading) const LinearProgressIndicator(),
            _dayBar(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 16), children: [
                  if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: kAmber))),
                  _boxCard(l, waiting, h24),
                  if (l.eaten.isNotEmpty) _eatenCard(l, h24),
                  if (l.isPast && waiting.isNotEmpty) _notEatenCard(waiting),
                ]),
              ),
            ),
            if (!_edit && amounts.isNotEmpty) _sendBar(meal),
          ]),
        );
      },
    );
  }

  Widget _dayBar() {
    final today = SchoolLunch.dayKey(DateTime.now());
    final next = _nextSchoolDay;
    return SizedBox(
      height: 48,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 6, 12, 0), children: [
        for (final d in {today, next, if (_day != today && _day != next) _day})
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(_dayLabel(d)),
              selected: _day == d,
              onSelected: (_) => setState(() {
                _day = d;
                _pick.clear();
                final l = app.lunchFor(d);
                _edit = l == null || l.isEmpty;
              }),
            ),
          ),
        ActionChip(
          avatar: const Icon(Icons.calendar_month, size: 18),
          label: const Text('Other day'),
          onPressed: () async {
            final now = DateTime.now();
            final d = await showDatePicker(
              context: context,
              initialDate: SchoolLunch.dayOf(_day) ?? now,
              firstDate: now.subtract(const Duration(days: 60)),
              lastDate: now.add(const Duration(days: 60)),
            );
            if (d != null) {
              setState(() {
                _day = SchoolLunch.dayKey(d);
                _pick.clear();
                final l = app.lunchFor(_day);
                _edit = l == null || l.isEmpty;
              });
            }
          },
        ),
      ]),
    );
  }

  Widget _card(String title, List<Widget> children, {Widget? trailing}) => Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            if (trailing != null) trailing,
          ]),
          const SizedBox(height: 4),
          ...children,
        ]),
      );

  Widget _boxCard(SchoolLunch l, List<LunchItem> waiting, bool h24) {
    final shown = _edit ? l.items.where((i) => !i.done).toList() : waiting;
    final leftCarbs = waiting.fold(0.0, (a, i) => a + (i.leftNutrition.carbs ?? 0));
    return _card(
      'In the lunch box',
      [
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              l.isEmpty
                  ? (_edit ? 'Add what is in the lunch box: it shows on every phone and in the web app.' : 'No lunch prepared for this day.')
                  : 'Everything has been eaten.',
              style: const TextStyle(color: kMuted),
            ),
          ),
        if (!_edit && shown.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text('Tick what you eat now, then send it.', style: TextStyle(color: kMuted, fontSize: 13)),
          ),
        for (final i in shown) _edit ? _packRow(i) : _eatRow(i),
        if (_edit) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(onPressed: _busy ? null : _addFromMyFoods, icon: const Icon(Icons.add), label: const Text('Add from my foods')),
            OutlinedButton.icon(onPressed: _busy ? null : _lookup, icon: const Icon(Icons.manage_search), label: const Text('Look up a food')),
          ]),
        ],
      ],
      trailing: waiting.isEmpty ? null : Text('${leftCarbs.round()} g carbs', style: kMono.copyWith(color: kMuted)),
    );
  }

  Widget _packRow(LunchItem i) {
    final c = i.food.forAmount(i.amount).carbs ?? 0;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: GlutenBadge(i.food.gluten),
      title: Text(i.food.name),
      subtitle: Text('${fmtAmount(i.amount)} ${unitFor(i.amount, i.food.unit)} · ${fmtAmount((c * 10).round() / 10)} g carbs'
          '${i.eaten > 0 ? ' · ${fmtAmount(i.eaten)} eaten' : ''}'),
      onTap: () async {
        final a = await _askAmount(i.food, start: i.amount);
        if (a == null) return;
        await _change((l) {
          final x = l.items.where((y) => y.key == i.key).firstOrNull;
          if (x != null) x.amount = a < x.eaten ? x.eaten : a;
        });
      },
      trailing: i.eaten > 0
          ? null
          : IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close),
              onPressed: () => _change((l) => l.items.removeWhere((y) => y.key == i.key)),
            ),
    );
  }

  Widget _eatRow(LunchItem i) {
    final part = _pick[i.key];
    final on = part != null;
    final eatNow = i.left * (part ?? 1);
    final c = i.food.forAmount(eatNow).carbs ?? 0;
    final past = _lunch.isPast;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: on ? kAccent.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: on ? kAccent : kBorder),
      ),
      child: Column(children: [
        CheckboxListTile(
          value: on,
          enabled: !past,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: const EdgeInsets.only(left: 4, right: 10),
          title: Row(children: [
            Expanded(child: Text(i.food.name, style: const TextStyle(fontWeight: FontWeight.w600))),
            GlutenBadge(i.food.gluten),
          ]),
          subtitle: Text('${fmtAmount(eatNow)} ${unitFor(eatNow, i.food.unit)} · ${fmtAmount((c * 10).round() / 10)} g carbs'
              '${i.eaten > 0 ? ' (part already eaten)' : ''}'),
          onChanged: (v) => setState(() => v == true ? _pick[i.key] = 1 : _pick.remove(i.key)),
        ),
        if (on)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: SegmentedButton<double>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 1, label: Text('All')),
                ButtonSegment(value: 0.75, label: Text('¾')),
                ButtonSegment(value: 0.5, label: Text('½')),
                ButtonSegment(value: 0.25, label: Text('¼')),
              ],
              selected: {part},
              onSelectionChanged: (v) => setState(() => _pick[i.key] = v.first),
            ),
          ),
      ]),
    );
  }

  Widget _eatenCard(SchoolLunch l, bool h24) {
    final list = [...l.eaten]..sort((a, b) => a.at.compareTo(b.at));
    final total = list.fold(0.0, (a, e) => a + e.carbs);
    return _card(
      'Eaten',
      [
        for (final e in list)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              SizedBox(width: 62, child: Text(fmtClock(e.at, h24), style: kMono.copyWith(color: kMuted))),
              Expanded(child: Text('${e.name}  ${fmtAmount(e.amount)} ${unitFor(e.amount, e.unit)}')),
              Text('${fmtAmount((e.carbs * 10).round() / 10)} g', style: kMono),
              const SizedBox(width: 6),
              Icon(e.how == 'loop' ? Icons.send : Icons.save_outlined, size: 15, color: kMuted),
            ]),
          ),
      ],
      trailing: Text('${total.round()} g carbs', style: kMono.copyWith(color: kGreen)),
    );
  }

  Widget _notEatenCard(List<LunchItem> waiting) => _card('Not eaten (came back home)', [
        for (final i in waiting)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text('${i.food.name}  ${fmtAmount(i.left)} ${unitFor(i.left, i.food.unit)}', style: const TextStyle(color: kMuted)),
          ),
      ]);

  Widget _sendBar(Meal meal) {
    final canLog = kRemote || app.settings.flag('allowTreatments');
    return Container(
      decoration: const BoxDecoration(color: kCard, border: Border(top: BorderSide(color: kBorder))),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('Eating now', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            GlutenBadge(meal.gluten),
            const Spacer(),
            Text('${meal.carbs.round()} g carbs', style: kMono.copyWith(fontSize: 18, fontWeight: FontWeight.w700, color: kAccent)),
          ]),
          if (!_today)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('This is the lunch of ${_dayLabel(_day)}.', style: const TextStyle(color: kAmber, fontSize: 12.5)),
            ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: _busy || !canLog ? null : _send,
              icon: Icon(kRemote ? Icons.send : Icons.save_outlined),
              label: Text(kRemote ? 'Send ${meal.carbs.round()} g to Loop' : 'Log ${meal.carbs.round()} g eaten',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}
