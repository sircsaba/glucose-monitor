import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../logic/glucose.dart';
import '../logic/insulin.dart';
import '../logic/profile.dart';
import '../logic/report.dart';
import '../report/report_pdf.dart';
import '../state/app_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'report_charts.dart';

/// Reports like Nightscout's: a summary, day to day, daily stats and the
/// distribution, for 1 to 90 days, each printable as a PDF.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

const _periods = [1, 7, 14, 30, 90];
const reportTabs = ['Summary', 'Day to day', 'Daily stats', 'Distribution'];

class _ReportsScreenState extends State<ReportsScreen> {
  int _days = 14;
  int _tab = 0;
  Future<ReportData>? _future;
  int _loadedDays = 0;
  bool _printing = false;

  void _load() {
    _loadedDays = _days;
    _future = loadReport(_days);
  }

  Future<void> _print(bool all, ReportData data) async {
    setState(() => _printing = true);
    try {
      await printReport(data, all ? const {0, 1, 2, 3} : {_tab});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not make the PDF: $e')));
    }
    if (mounted) setState(() => _printing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_future == null || _loadedDays != _days) _load();
    return FutureBuilder<ReportData>(
      future: _future,
      builder: (context, snap) {
        final data = snap.connectionState == ConnectionState.done && !snap.hasError ? snap.data : null;
        final head = Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 6, children: [
          const Text('Reports', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          for (final d in _periods)
            ChoiceChip(label: Text(d == 1 ? 'Today' : '${d}d'), selected: _days == d, onSelected: (_) => setState(() => _days = d)),
          PopupMenuButton<bool>(
            enabled: data != null && data.bg != null && !_printing,
            tooltip: 'Print or save as PDF',
            icon: _printing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.print_outlined),
            onSelected: (all) => _print(all, data!),
            itemBuilder: (_) => [
              PopupMenuItem(value: false, child: Text('PDF: ${reportTabs[_tab]}')),
              const PopupMenuItem(value: true, child: Text('PDF: all reports')),
            ],
          ),
        ]);
        final tabs = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (var i = 0; i < reportTabs.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(reportTabs[i]), selected: _tab == i, onSelected: (_) => setState(() => _tab = i)),
              ),
          ]),
        );
        List<Widget> body;
        if (snap.connectionState != ConnectionState.done) {
          body = [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))];
        } else if (snap.hasError) {
          body = [Padding(padding: const EdgeInsets.all(20), child: Text(snap.error.toString(), style: const TextStyle(color: kAmber)))];
        } else if (data == null || data.bg == null) {
          body = [const Padding(padding: EdgeInsets.all(20), child: Text('No readings in this period.'))];
        } else {
          body = switch (_tab) {
            1 => _dayToDay(data),
            2 => _dailyStats(data),
            3 => _distribution(data),
            _ => _summary(data),
          };
        }
        return RefreshIndicator(
          onRefresh: () async => setState(_load),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [head, const SizedBox(height: 10), tabs, const SizedBox(height: 14), ...body],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- helpers

  bool get _mmol => app.mmol;
  String _bg(double mg) => fmtBg(mg, _mmol);
  String _p(double f) => '${(f * 100).round()}%';
  Color get _tightColor => Color(app.settings.integer('ttirColor'));

  Widget _card(List<Widget> children, {EdgeInsets padding = const EdgeInsets.all(14)}) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: padding,
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _tile(String label, String value, {Color? color, String? sub}) => Container(
        width: 150,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: kMono.copyWith(fontSize: 20, fontWeight: FontWeight.w600, color: color ?? kText)),
          ),
          if (sub != null) Text(sub, style: const TextStyle(color: kMuted, fontSize: 11)),
        ]),
      );

  Widget _legend(List<PieSlice> slices, double total) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        for (final s in slices)
          if (s.value > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 6),
                Text(s.label, style: const TextStyle(fontSize: 12, color: kMuted)),
                const SizedBox(width: 6),
                Text(total > 0 ? '${(s.value / total * 100).round()}%' : '', style: kMono.copyWith(fontSize: 12)),
              ]),
            ),
      ]);

  Widget _rangeBar(BgSummary b, double height) {
    final slices = rangeSlices(b, _tightColor, app.settings.flag('ttirOn'));
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Row(children: [
          for (final s in slices)
            if (s.value > 0) Expanded(flex: math.max(1, (s.value * 1000).round()), child: Container(color: s.color)),
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------- summary

  List<Widget> _summary(ReportData d) {
    final b = d.bg!;
    final ttir = d.ttirOn;
    final ins = d.ins;
    final insSlices = insulinSlices(ins);
    final tirSlices = rangeSlices(b, _tightColor, ttir);
    return [
      _card([
        Row(children: [
          const Expanded(child: Text('Time in range', style: TextStyle(color: kMuted, fontSize: 13))),
          Text(_p(b.inRange), style: kMono.copyWith(fontSize: 30, fontWeight: FontWeight.w600, color: kGreen)),
        ]),
        if (ttir)
          Row(children: [
            Expanded(
              child: Text('Time in tight range (${_bg(d.lo)}–${_bg(d.tightHi)})', style: const TextStyle(color: kMuted, fontSize: 13)),
            ),
            Text(_p(b.tight), style: kMono.copyWith(fontSize: 24, fontWeight: FontWeight.w600, color: kGreen)),
          ]),
        const SizedBox(height: 8),
        _rangeBar(b, 14),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: Text('Below ${_p(b.below)}', style: const TextStyle(color: kMuted, fontSize: 12))),
          Text(ttir ? '${_bg(d.lo)}–${_bg(d.tightHi)}–${_bg(d.hi)}' : '${_bg(d.lo)}–${_bg(d.hi)}', style: const TextStyle(color: kMuted, fontSize: 12)),
          Expanded(child: Text('Above ${_p(b.above)}', textAlign: TextAlign.right, style: const TextStyle(color: kMuted, fontSize: 12))),
        ]),
      ]),
      Wrap(spacing: 10, runSpacing: 10, children: [
        _pieCard('Time in ranges', tirSlices, null),
        _pieCard('Insulin (period)', insSlices, '${fmtU(_r1(d.avgTdd))} U/day'),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in summaryStats(d, _mmol)) _tile(s.$1, s.$2, sub: s.$3),
      ]),
      const SizedBox(height: 10),
      _card([
        const Text('Profile by time of day', style: TextStyle(color: kMuted, fontSize: 13)),
        const SizedBox(height: 6),
        SizedBox(
          height: 210,
          child: CustomPaint(
            painter: AgpPainter(d.agp, d.lo, d.hi, _mmol, tightHi: ttir ? d.tightHi : null, tightColor: _tightColor),
            size: Size.infinite,
          ),
        ),
      ], padding: const EdgeInsets.fromLTRB(10, 12, 10, 8)),
    ];
  }

  Widget _pieCard(String title, List<PieSlice> slices, String? center) {
    final total = slices.fold(0.0, (a, s) => a + s.value);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(title, style: const TextStyle(color: kMuted, fontSize: 13)),
        const SizedBox(height: 8),
        Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 130, height: 130, child: CustomPaint(painter: PiePainter(slices, center: center))),
          const SizedBox(width: 12),
          _legend(slices, total),
        ]),
      ]),
    );
  }

  // ---------------------------------------------------------------- day to day

  List<Widget> _dayToDay(ReportData d) {
    final ttir = d.ttirOn;
    return [
      for (final day in d.days)
        _card([
          Row(children: [
            Expanded(child: Text(dayTitle(day.day), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            if (day.bg != null)
              Text(ttir ? 'TIR ${_p(day.bg!.inRange)} · TTIR ${_p(day.bg!.tight)}' : 'TIR ${_p(day.bg!.inRange)}',
                  style: kMono.copyWith(fontSize: 12, color: kGreen)),
          ]),
          const SizedBox(height: 6),
          SizedBox(
            height: 230,
            child: CustomPaint(
              painter: DayChartPainter(
                day: day.day,
                entries: day.entries,
                treatments: d.treatments,
                profiles: d.profiles,
                lo: d.lo,
                hi: d.hi,
                tightHi: ttir ? d.tightHi : null,
                tightColor: _tightColor,
                mmol: _mmol,
                theme: ChartTheme.dark,
              ),
              size: Size.infinite,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 14, runSpacing: 4, children: [
            for (final kv in dayTotals(day, _mmol))
              Text.rich(TextSpan(children: [
                TextSpan(text: '${kv.$1} ', style: const TextStyle(color: kMuted, fontSize: 12)),
                TextSpan(text: kv.$2, style: kMono.copyWith(fontSize: 13)),
              ])),
          ]),
        ], padding: const EdgeInsets.fromLTRB(10, 12, 10, 10)),
    ];
  }

  // ---------------------------------------------------------------- tables

  Widget _table(List<List<String>> rows, Set<int> textColumns) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 34,
          dataRowMinHeight: 28,
          dataRowMaxHeight: 32,
          columnSpacing: 14,
          horizontalMargin: 6,
          headingTextStyle: const TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.w600),
          dataTextStyle: kMono.copyWith(fontSize: 12, color: kText),
          columns: [
            for (var i = 0; i < rows.first.length; i++) DataColumn(label: Text(rows.first[i]), numeric: !textColumns.contains(i)),
          ],
          rows: [
            for (var i = 1; i < rows.length; i++)
              DataRow(
                color: i == rows.length - 1 ? WidgetStateProperty.all(kLine) : null,
                cells: [for (final c in rows[i]) DataCell(Text(c))],
              ),
          ],
        ),
      );

  List<Widget> _dailyStats(ReportData d) => [
        _card([
          Text('Glucose in ${unitLabel(_mmol)}, insulin in units, carbs in grams.', style: const TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 8),
          _table(dailyStatsRows(d, _mmol), const {0}),
        ], padding: const EdgeInsets.all(10)),
      ];

  List<Widget> _distribution(ReportData d) {
    final ttir = d.ttirOn;
    final colors = rangeColorList(_tightColor, ttir);
    final names = ['Very low', 'Low', ttir ? 'Tight range' : 'In range', if (ttir) 'Range above tight', 'High', 'Very high'];
    final legendColors = [colors[0], colors[1], colors[2], if (ttir) colors[3], colors[4], colors[5]];
    return [
      _card([_table(distributionRows(d, _mmol), const {0, 1})], padding: const EdgeInsets.all(10)),
      _card([
        const Text('Time in each range by hour of day', style: TextStyle(color: kMuted, fontSize: 13)),
        const SizedBox(height: 8),
        SizedBox(height: 200, child: CustomPaint(painter: HourlyPainter(d.hourly, colors), size: Size.infinite)),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 4, children: [
          for (var i = 0; i < names.length; i++)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 10, height: 10, color: legendColors[i]),
              const SizedBox(width: 4),
              Text(names[i], style: const TextStyle(color: kMuted, fontSize: 12)),
            ]),
        ]),
      ], padding: const EdgeInsets.fromLTRB(10, 12, 10, 10)),
      _card([
        for (final kv in variabilityRows(d, _mmol))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(kv.$1, style: const TextStyle(color: kMuted, fontSize: 13))),
              Text(kv.$2, style: kMono.copyWith(fontSize: 13)),
            ]),
          ),
      ]),
    ];
  }

  static double _r1(double v) => (v * 10).round() / 10;
}

// ------------------------------------------------------------------ shared with the PDF

/// Loads readings, treatments and profiles for the last [days] calendar days
/// (1 = today since midnight).
Future<ReportData> loadReport(int days) async {
  final now = DateTime.now();
  final from = DateTime(now.year, now.month, now.day - (days - 1));
  final c = app.client;
  final entriesF = c.entriesBetween(from, now);
  final treatF = c.treatmentsBetween(from.subtract(const Duration(hours: 6)), now);
  final profF = c.profiles();
  final entries = await entriesF;
  final treatments = await treatF;
  List<ProfileDoc> profiles;
  try {
    profiles = await profF;
  } catch (_) {
    profiles = app.profiles;
  }
  final s = app.settings;
  return ReportData(
    from: from,
    to: now,
    entries: entries,
    treatments: treatments,
    profiles: profiles,
    lo: s.number('tirLo'),
    hi: s.number('tirHi'),
    tightHi: s.number('ttirHi'),
    ttirOn: s.flag('ttirOn'),
  );
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

String dayTitle(DateTime d) => '${_weekdays[d.weekday - 1]} ${d.year}-${two(d.month)}-${two(d.day)}';

double _round1(double v) => (v * 10).round() / 10;

List<PieSlice> insulinSlices(InsulinTotals ins) => [
      PieSlice(ins.totalBasal, RangeColors.basal, 'Basal ${fmtU(_round1(ins.totalBasal))} U'),
      PieSlice(ins.manualBolus, RangeColors.bolus, 'Bolus ${fmtU(_round1(ins.manualBolus))} U'),
      PieSlice(ins.autoBolus, RangeColors.autoBolus, 'Auto bolus ${fmtU(_round1(ins.autoBolus))} U'),
    ];

/// The figures on the summary: (name, value, note).
List<(String, String, String?)> summaryStats(ReportData d, bool mmol) {
  final b = d.bg!;
  final ins = d.ins;
  String bg(double v) => fmtBg(v, mmol);
  final unit = unitLabel(mmol);
  final isf = d.avgTdd > 1 ? 1800 / d.avgTdd : null;
  return [
    ('Average', bg(b.avg), unit),
    ('Median', bg(b.median), unit),
    ('Est. A1c (GMI)', '${b.gmi.toStringAsFixed(1)}%', null),
    ('Std deviation', bg(b.sd), unit),
    ('CV', '${b.cv.round()}%', 'goal 36% or less'),
    ('Lowest / highest', '${bg(b.min)} / ${bg(b.max)}', unit),
    ('Low episodes', '${d.lowEpisodes}', 'below range 15 min+'),
    ('Readings', '${b.count}', 'sensor use ${(d.sensorUse * 100).round()}%'),
    ('Carbs per day', '${d.avgCarbs.round()} g', null),
    ('Insulin per day', '${fmtU(_round1(d.avgTdd))} U', 'basal ${ins.basalPct.round()}%'),
    ('Bolus per day', '${fmtU(_round1(d.avgBolus))} U', null),
    ('Basal per day', '${fmtU(_round1(d.avgBasal))} U', null),
    if (ins.icrManual != null) ('Carb ratio (actual)', '1:${ins.icrManual!.toStringAsFixed(1)}', 'carbs / manual boluses'),
    if (ins.icrAll != null) ('Carb ratio (all)', '1:${ins.icrAll!.toStringAsFixed(1)}', 'auto boluses included'),
    if (isf != null) ('ISF estimate', mmol ? (isf / mgPerMmol).toStringAsFixed(1) : isf.round().toString(), '1800 rule, $unit/U'),
    ('GVI', d.gvi.toStringAsFixed(2), '1.0 = flat line'),
    ('PGS', d.pgs.round().toString(), 'lower is better'),
    ('LBGI / HBGI', '${d.lbgi.toStringAsFixed(1)} / ${d.hbgi.toStringAsFixed(1)}', 'low / high risk'),
    ('Daily change', bg(d.dailyChange), '$unit moved per day'),
  ];
}

/// The totals under each day's graph.
List<(String, String)> dayTotals(DayReport day, bool mmol) {
  final i = day.ins;
  return [
    ('Bolus', '${fmtU(_round1(i.bolus))} U${i.autoBolus > 0 ? ' (auto ${fmtU(_round1(i.autoBolus))})' : ''}'),
    ('Base basal', '${fmtU(_round1(i.baseBasal))} U'),
    ('Temp basal +', '${fmtU(_round1(i.tempPlus))} U'),
    ('Temp basal -', '${fmtU(_round1(-i.tempMinus))} U'),
    ('Total basal', '${fmtU(_round1(i.totalBasal))} U'),
    ('Total insulin', '${fmtU(_round1(i.total))} U'),
    ('Basal / bolus', '${i.basalPct.round()}% / ${(100 - i.basalPct).round()}%'),
    ('Carbs', '${i.carbs.round()} g'),
    if (i.icrManual != null) ('Carb ratio', '1:${i.icrManual!.toStringAsFixed(1)}'),
    if (i.isfRule != null && i.hours >= 20) ('ISF est.', mmol ? (i.isfRule! / mgPerMmol).toStringAsFixed(1) : i.isfRule!.round().toString()),
    if (day.bg != null) ('Average', fmtBg(day.bg!.avg, mmol)),
    if (day.lows > 0) ('Lows', '${day.lows}'),
  ];
}

/// Daily stats table: header row, one row per day, then the period.
List<List<String>> dailyStatsRows(ReportData d, bool mmol) {
  String bg(double v) => fmtBg(v, mmol);
  String p(double f) => '${(f * 100).round()}%';
  List<String> row(String name, BgSummary? b, InsulinTotals ins) => [
        name,
        b == null ? '' : p(b.veryLow),
        b == null ? '' : p(b.low),
        if (d.ttirOn) b == null ? '' : p(b.tight),
        b == null ? '' : p(b.inRange),
        b == null ? '' : p(b.high),
        b == null ? '' : p(b.veryHigh),
        b == null ? '0' : '${b.count}',
        b == null ? '' : bg(b.min),
        b == null ? '' : bg(b.max),
        b == null ? '' : bg(b.avg),
        b == null ? '' : bg(b.sd),
        b == null ? '' : '${b.cv.round()}%',
        b == null ? '' : bg(b.q25),
        b == null ? '' : bg(b.median),
        b == null ? '' : bg(b.q75),
        '${ins.carbs.round()}',
        fmtU(_round1(ins.bolus)),
        fmtU(_round1(ins.totalBasal)),
        fmtU(_round1(ins.total)),
      ];
  return [
    ['Date', 'V.low', 'Low', if (d.ttirOn) 'Tight', 'In range', 'High', 'V.high', 'Readings', 'Min', 'Max', 'Avg', 'SD', 'CV', '25%', 'Median', '75%', 'Carbs', 'Bolus', 'Basal', 'Total'],
    for (final day in d.days) row('${day.day.year}-${two(day.day.month)}-${two(day.day.day)}', day.bg, day.ins),
    row('Period', d.bg, d.ins),
  ];
}

/// Distribution table: header, one row per range, then all readings.
List<List<String>> distributionRows(ReportData d, bool mmol) {
  String bg(double v) => fmtBg(v, mmol);
  String limits(RangeRow r) {
    if (r.from <= 0) return 'under ${bg(r.to)}';
    if (r.to >= 10000) return 'over ${bg(r.from)}';
    return '${bg(r.from)}-${bg(r.to)}';
  }

  final b = d.bg!;
  return [
    ['Range', 'Limits', '% of time', 'Readings', 'Average', 'Median', 'SD'],
    for (final r in d.ranges)
      [r.name, limits(r), '${(r.share * 100).toStringAsFixed(1)}%', '${r.count}', r.count == 0 ? '' : bg(r.avg), r.count == 0 ? '' : bg(r.median), r.count == 0 ? '' : bg(r.sd)],
    ['All', '', '100%', '${b.count}', bg(b.avg), bg(b.median), bg(b.sd)],
  ];
}

/// Variability and risk figures shown under the distribution.
List<(String, String)> variabilityRows(ReportData d, bool mmol) {
  final b = d.bg!;
  return [
    ('Estimated A1c (GMI)', '${b.gmi.toStringAsFixed(1)}%'),
    ('Average / median', '${fmtBg(b.avg, mmol)} / ${fmtBg(b.median, mmol)} ${unitLabel(mmol)}'),
    ('Standard deviation / CV', '${fmtBg(b.sd, mmol)} / ${b.cv.round()}%'),
    ('Glycemic variability index (GVI)', '${d.gvi.toStringAsFixed(2)}  (under 1.2 good, over 1.5 high)'),
    ('Patient glycemic status (PGS)', '${d.pgs.round()}  (under 35 excellent, over 100 poor)'),
    ('Low / high blood glucose index', '${d.lbgi.toStringAsFixed(1)} / ${d.hbgi.toStringAsFixed(1)}'),
    ('Mean total daily change', '${fmtBg(d.dailyChange, mmol)} ${unitLabel(mmol)}'),
    ('Low episodes (15 min or more)', '${d.lowEpisodes}'),
    ('Sensor use', '${(d.sensorUse * 100).round()}%'),
  ];
}
