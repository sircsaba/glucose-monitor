import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/nightscout.dart';
import '../logic/glucose.dart';
import '../logic/stats.dart';
import '../state/app_state.dart';
import 'common.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  int _days = 14;
  Future<List<Entry>>? _future;
  int _loadedDays = 0;

  void _load() {
    _loadedDays = _days;
    _future = app.client.entriesSince(DateTime.now().subtract(Duration(days: _days)), count: _days * 1500);
  }

  Widget _tile(String label, String value, {Color? color, String? sub}) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value, style: kMono.copyWith(fontSize: 22, fontWeight: FontWeight.w600, color: color ?? kText)),
          if (sub != null) Text(sub, style: const TextStyle(color: kMuted, fontSize: 11)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (_future == null || _loadedDays != _days) _load();
    final s = app.settings;
    final mmol = s.mmol;
    final lo = s.number('tirLo');
    final hi = s.number('tirHi');
    return FutureBuilder<List<Entry>>(
      future: _future,
      builder: (context, snap) {
        final head = Row(children: [
          const Expanded(child: Text('Reports', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600))),
          for (final d in [7, 14, 30])
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: ChoiceChip(label: Text('${d}d'), selected: _days == d, onSelected: (_) => setState(() => _days = d)),
            ),
        ]);
        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
        } else if (snap.hasError) {
          body = Padding(padding: const EdgeInsets.all(20), child: Text(snap.error.toString(), style: const TextStyle(color: kAmber)));
        } else {
          final st = computeStats(snap.data ?? const [], lo, hi, _days);
          if (st == null) {
            body = const Padding(padding: EdgeInsets.all(20), child: Text('No readings in this period.'));
          } else {
            body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    const Expanded(child: Text('Time in range', style: TextStyle(color: kMuted, fontSize: 13))),
                    Text('${(st.inRange * 100).round()}%', style: kMono.copyWith(fontSize: 30, fontWeight: FontWeight.w600, color: kGreen)),
                  ]),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: SizedBox(
                      height: 14,
                      child: Row(children: [
                        Expanded(flex: math.max(1, (st.below * 1000).round()), child: Container(color: kRed)),
                        Expanded(flex: math.max(1, (st.inRange * 1000).round()), child: Container(color: kGreen)),
                        Expanded(flex: math.max(1, (st.above * 1000).round()), child: Container(color: kYellow)),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(child: Text('Below ${(st.below * 100).round()}%', style: const TextStyle(color: kMuted, fontSize: 12))),
                    Text('${fmtBg(lo, mmol)}–${fmtBg(hi, mmol)}', style: const TextStyle(color: kMuted, fontSize: 12)),
                    Expanded(
                      child: Text('Above ${(st.above * 100).round()}%',
                          textAlign: TextAlign.right, style: const TextStyle(color: kMuted, fontSize: 12)),
                    ),
                  ]),
                ]),
              ),
              const SizedBox(height: 10),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.25,
                children: [
                  _tile('Average', fmtBg(st.avg, mmol), sub: unitLabel(mmol)),
                  _tile('Est. A1c', '${st.gmi.toStringAsFixed(1)}%', sub: 'GMI'),
                  _tile('CV', '${st.cv.round()}%', sub: 'goal ≤36%'),
                  _tile('Readings', '${st.count}'),
                  _tile('Sensor use', '${(st.sensorUse * 100).round()}%'),
                  _tile('Days', '$_days'),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 8, bottom: 6),
                    child: Text('Profile by time of day', style: TextStyle(color: kMuted, fontSize: 13)),
                  ),
                  SizedBox(height: 200, child: CustomPaint(painter: _AgpPainter(st.agp, lo, hi, mmol), size: Size.infinite)),
                ]),
              ),
              const SizedBox(height: 10),
              Section(title: 'Each day', padding: const EdgeInsets.all(12), children: [
                for (final d in st.days.reversed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      SizedBox(width: 56, child: Text('${two(d.day.month)}-${two(d.day.day)}', style: kMono.copyWith(color: kMuted, fontSize: 12))),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: SizedBox(
                            height: 12,
                            child: Row(children: [
                              Expanded(flex: math.max(1, (d.below * 1000).round()), child: Container(color: kRed)),
                              Expanded(flex: math.max(1, (d.inRange * 1000).round()), child: Container(color: kGreen)),
                              Expanded(flex: math.max(1, (d.above * 1000).round()), child: Container(color: kYellow)),
                            ]),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text('${(d.inRange * 100).round()}%', textAlign: TextAlign.right, style: kMono.copyWith(fontSize: 12)),
                      ),
                    ]),
                  ),
              ]),
            ]);
          }
        }
        return RefreshIndicator(
          onRefresh: () async => setState(_load),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [head, const SizedBox(height: 14), body]),
        );
      },
    );
  }
}

class _AgpPainter extends CustomPainter {
  final List<List<double>> agp;
  final double lo;
  final double hi;
  final bool mmol;
  _AgpPainter(this.agp, this.lo, this.hi, this.mmol);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 26.0;
    const bottom = 16.0;
    final w = size.width - left - 4;
    final h = size.height - bottom;
    var maxMg = 270.0;
    for (final a in agp) {
      if (a.isNotEmpty) maxMg = math.max(maxMg, a[4] + 10);
    }
    const minMg = 36.0;
    double y(double mg) => (1 - (mg - minMg) / (maxMg - minMg)) * h;
    double x(int slot) => left + (slot + 0.5) / 48 * w;
    canvas.drawRect(Rect.fromLTRB(left, y(hi), left + w, y(lo)), Paint()..color = kGreen.withValues(alpha: 0.08));

    void band(int a, int b, Color c) {
      final path = Path();
      var started = false;
      for (var i = 0; i < 48; i++) {
        if (agp[i].isEmpty) continue;
        final p = Offset(x(i), y(agp[i][b]));
        if (!started) {
          path.moveTo(p.dx, p.dy);
          started = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      for (var i = 47; i >= 0; i--) {
        if (agp[i].isEmpty) continue;
        path.lineTo(x(i), y(agp[i][a]));
      }
      if (started) {
        path.close();
        canvas.drawPath(path, Paint()..color = c);
      }
    }

    band(0, 4, const Color(0xFF1D3A4A));
    band(1, 3, const Color(0xFF2E6A86));
    final med = Path();
    var started = false;
    for (var i = 0; i < 48; i++) {
      if (agp[i].isEmpty) continue;
      if (!started) {
        med.moveTo(x(i), y(agp[i][2]));
        started = true;
      } else {
        med.lineTo(x(i), y(agp[i][2]));
      }
    }
    canvas.drawPath(
      med,
      Paint()
        ..color = kText
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (final hr in [0, 6, 12, 18, 24]) {
      final tp = TextPainter(
        text: TextSpan(text: '${two(hr)}h', style: const TextStyle(color: kMuted, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(left + hr / 24 * w - tp.width / 2, h + 3));
    }
    for (final g in (mmol ? [4.0, 10.0, 16.0] : [70.0, 180.0, 288.0])) {
      final mg = mmol ? g * 18.0182 : g;
      if (mg > maxMg) continue;
      final tp = TextPainter(
        text: TextSpan(text: g.toStringAsFixed(0), style: const TextStyle(color: kMuted, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(left - tp.width - 4, y(mg) - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
