import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../logic/glucose.dart';
import '../../state/app_state.dart';
import '../../state/settings.dart';
import '../common.dart';

const _palette = [Color(0xFF5BC0EB), Color(0xFFB39DFF), Color(0xFFF08BD0), Color(0xFF7FD1AE), Color(0xFFE9A06B), Color(0xFF9AA4B2)];

class ZonesScreen extends StatefulWidget {
  const ZonesScreen({super.key});
  @override
  State<ZonesScreen> createState() => _ZonesScreenState();
}

class _ZonesScreenState extends State<ZonesScreen> {
  int _sel = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BG zones & time ranges')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final s = app.settings;
          final ranges = s.ranges;
          _sel = _sel.clamp(0, ranges.length - 1);
          final cur = ranges[_sel];
          final mmol = s.mmol;
          final h24 = s.flag('time24');
          final today = DateTime.now();

          // Which range applies in each half hour today.
          final slots = List.generate(48, (k) {
            final t = DateTime(today.year, today.month, today.day, k ~/ 2, (k % 2) * 30);
            for (var i = 0; i < ranges.length; i++) {
              if (ranges[i].covers(t)) return _palette[i % _palette.length];
            }
            return kBorder;
          });

          double w(double a, double b) => math.max(0.0, math.min(b, 360.0) - math.max(a, 36.0));
          final step = mmol ? mgPerMmol / 10 : 1.0;
          double sc(double v, double lo, double hi) => hi < lo ? lo : v.clamp(lo, hi);
          void setLimit(String k, double v) => app.change((x) {
                final r = x.ranges[_sel];
                switch (k) {
                  case 'redLo':
                    r.redLo = sc(v, 36.0, r.yelLo - step);
                    break;
                  case 'yelLo':
                    r.yelLo = sc(v, r.redLo + step, r.yelHi - step);
                    break;
                  case 'yelHi':
                    r.yelHi = sc(v, r.yelLo + step, r.redHi - step);
                    break;
                  case 'redHi':
                    r.redHi = sc(v, r.yelHi + step, 450.0);
                    break;
                }
              });

          Widget limit(String key, String label, String hint, Color c, double v) => RowBox(
                child: Row(children: [
                  Container(width: 14, height: 14, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label),
                      Text(hint, style: const TextStyle(color: kMuted, fontSize: 12)),
                    ]),
                  ),
                  RoundButton('−', () => setLimit(key, v - step), semantic: 'Lower $label'),
                  SizedBox(width: 56, child: Text(fmtBg(v, mmol), textAlign: TextAlign.center, style: kMono.copyWith(fontSize: 16))),
                  RoundButton('+', () => setLimit(key, v + step), semantic: 'Raise $label'),
                ]),
              );

          const dayNames = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
            const Text(
              'Each time range has its own red, yellow and green limits. Where ranges overlap, the one higher in the list wins. '
              'Outside every range, the top range applies.',
              style: TextStyle(color: kMuted, fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 14),
            Section(title: 'Today', padding: const EdgeInsets.all(12), children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: 22,
                  child: Row(children: [for (final c in slots) Expanded(child: Container(color: c, margin: const EdgeInsets.only(right: 1)))]),
                ),
              ),
              const SizedBox(height: 4),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                for (final h in ['00', '06', '12', '18', '24']) Text(h, style: kMono.copyWith(color: kMuted, fontSize: 11)),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 12, runSpacing: 4, children: [
                for (var i = 0; i < ranges.length; i++)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 10, height: 10, color: _palette[i % _palette.length]),
                    const SizedBox(width: 6),
                    Text('${ranges[i].name} ${fmtMinutesOfDay(ranges[i].from, h24)}–${fmtMinutesOfDay(ranges[i].to, h24)}',
                        style: const TextStyle(fontSize: 12)),
                  ]),
              ]),
            ]),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (var i = 0; i < ranges.length; i++)
                ChoiceChip(
                  label: Text(ranges[i].name),
                  selected: i == _sel,
                  side: BorderSide(color: _palette[i % _palette.length], width: i == _sel ? 2 : 1),
                  onSelected: (_) => setState(() => _sel = i),
                ),
              ActionChip(
                label: const Text('+ Add range'),
                onPressed: () {
                  app.change((x) {
                    final n = x.ranges[_sel].copy()
                      ..name = 'Range ${x.ranges.length + 1}'
                      ..from = 720
                      ..to = 780;
                    x.ranges.add(n);
                  });
                  setState(() => _sel = app.settings.ranges.length - 1);
                },
              ),
            ]),
            const SizedBox(height: 14),
            Section(children: [
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: TextFormField(
                  key: ValueKey('name$_sel${ranges.length}'),
                  initialValue: cur.name,
                  decoration: const InputDecoration(labelText: 'Name'),
                  onChanged: (v) => app.change((x) => x.ranges[_sel].name = v.isEmpty ? 'Range' : v),
                ),
              ),
              StepRow(
                label: 'From',
                value: fmtMinutesOfDay(cur.from, h24),
                onMinus: () => app.change((x) => x.ranges[_sel].from = (cur.from + 1410) % 1440),
                onPlus: () => app.change((x) => x.ranges[_sel].from = (cur.from + 30) % 1440),
              ),
              StepRow(
                label: 'To',
                value: fmtMinutesOfDay(cur.to, h24),
                onMinus: () => app.change((x) => x.ranges[_sel].to = (cur.to + 1410) % 1440),
                onPlus: () => app.change((x) => x.ranges[_sel].to = (cur.to + 30) % 1440),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: FilterChip(
                          showCheckmark: false,
                          padding: EdgeInsets.zero,
                          labelPadding: EdgeInsets.zero,
                          label: Text(dayNames[i], textAlign: TextAlign.center),
                          selected: cur.days[i],
                          onSelected: (v) => app.change((x) => x.ranges[_sel].days[i] = v),
                        ),
                      ),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('Zones (${unitLabel(mmol)})', style: const TextStyle(color: kMuted, fontSize: 13)),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      height: 28,
                      child: Row(children: [
                        Expanded(flex: math.max(1, w(36, cur.redLo).round()), child: Container(color: kRed)),
                        Expanded(flex: math.max(1, w(cur.redLo, cur.yelLo).round()), child: Container(color: kYellow)),
                        Expanded(
                          flex: math.max(1, w(cur.yelLo, cur.yelHi).round()),
                          child: Container(
                            color: kGreen,
                            alignment: Alignment.center,
                            child: const Text('green', style: TextStyle(color: kBg, fontSize: 11, fontWeight: FontWeight.w600)),
                          ),
                        ),
                        Expanded(flex: math.max(1, w(cur.yelHi, cur.redHi).round()), child: Container(color: kYellow)),
                        Expanded(flex: math.max(1, w(cur.redHi, 360).round()), child: Container(color: kRed)),
                      ]),
                    ),
                  ),
                ]),
              ),
              limit('redLo', 'Red below', 'Urgent low zone', kRed, cur.redLo),
              limit('yelLo', 'Yellow below', 'Low warning starts', kYellow, cur.yelLo),
              limit('yelHi', 'Yellow above', 'High warning starts', kYellow, cur.yelHi),
              limit('redHi', 'Red above', 'Urgent high zone', kRed, cur.redHi),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Green ${fmtBg(cur.yelLo, mmol)}–${fmtBg(cur.yelHi, mmol)} · '
                  'Yellow ${fmtBg(cur.redLo, mmol)}–${fmtBg(cur.yelLo, mmol)} and ${fmtBg(cur.yelHi, mmol)}–${fmtBg(cur.redHi, mmol)} · '
                  'Red under ${fmtBg(cur.redLo, mmol)} or over ${fmtBg(cur.redHi, mmol)}',
                  style: const TextStyle(fontSize: 13, color: Color(0xFFC4CCD6)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _sel == 0
                          ? null
                          : () {
                              app.change((x) {
                                final r = x.ranges.removeAt(_sel);
                                x.ranges.insert(_sel - 1, r);
                              });
                              setState(() => _sel = _sel - 1);
                            },
                      child: const Text('Move up (higher priority)'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFFF6B76)),
                    onPressed: ranges.length <= 1
                        ? null
                        : () {
                            app.change((x) => x.ranges.removeAt(_sel));
                            setState(() => _sel = math.max(0, _sel - 1));
                          },
                    child: const Text('Delete'),
                  ),
                ]),
              ),
            ]),
          ]);
        },
      ),
    );
  }
}
