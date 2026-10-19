import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../data/nightscout.dart';
import '../logic/glucose.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Every treatment over a period (carbs, boluses, automatic boluses / SMB,
/// temp basals, overrides, site changes…), filtered by kind, with the columns
/// you choose, exported as a spreadsheet (CSV) or a PDF.
class TreatmentLogScreen extends StatefulWidget {
  const TreatmentLogScreen({super.key});
  @override
  State<TreatmentLogScreen> createState() => _TreatmentLogScreenState();
}

/// Kinds of treatment (a meal bolus with carbs is both Carbs and Bolus).
const tlKinds = {
  'carbs': 'Carbs',
  'bolus': 'Boluses',
  'auto': 'Automatic boluses / SMB',
  'basal': 'Temp basals',
  'preset': 'Overrides / temp targets',
  'profile': 'Profile switches',
  'device': 'Site, sensor, insulin changes',
  'other': 'Notes and other',
};

const tlColumns = {
  'date': 'Date',
  'time': 'Time',
  'type': 'Type',
  'insulin': 'Insulin (U)',
  'carbs': 'Carbs (g)',
  'rate': 'Basal rate (U/h)',
  'duration': 'Duration (min)',
  'target': 'Target',
  'notes': 'Notes / reason',
  'by': 'Entered by',
};

Set<String> tlKindsOf(Treatment t) {
  final out = <String>{};
  if ((t.carbs ?? 0) > 0) out.add('carbs');
  if ((t.insulin ?? 0) > 0 && t.type != 'Temp Basal') out.add(t.isSmb ? 'auto' : 'bolus');
  if (t.type == 'Temp Basal') out.add('basal');
  if (t.isPreset) out.add('preset');
  if (t.type == 'Profile Switch') out.add('profile');
  final ty = t.type.toLowerCase();
  if (out.isEmpty && (ty.contains('change') || ty.contains('sensor') || ty.contains('site') || ty.contains('battery'))) out.add('device');
  if (out.isEmpty) out.add('other');
  return out;
}

String _num(double? v, {int dec = 2}) {
  if (v == null) return '';
  var s = v.toStringAsFixed(dec);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return s;
}

/// One cell, as text, in the units the app shows.
String tlCell(Treatment t, String col, bool mmol) {
  switch (col) {
    case 'date':
      return '${t.t.year}-${two(t.t.month)}-${two(t.t.day)}';
    case 'time':
      return '${two(t.t.hour)}:${two(t.t.minute)}:${two(t.t.second)}';
    case 'type':
      if (t.type != 'Temp Basal' && (t.insulin ?? 0) > 0 && t.isSmb) return '${t.type} (automatic)';
      return t.type.isEmpty ? 'Treatment' : t.type;
    case 'insulin':
      return t.type == 'Temp Basal' ? '' : _num(t.insulin);
    case 'carbs':
      return _num(t.carbs, dec: 1);
    case 'rate':
      return t.type == 'Temp Basal' ? _num(t.absolute, dec: 3) : '';
    case 'duration':
      return _num(t.duration, dec: 0);
    case 'target':
      if (t.targetLo == null) return '';
      final lo = fmtBg(t.targetLo!, mmol), hi = fmtBg(t.targetHi ?? t.targetLo!, mmol);
      return lo == hi ? lo : '$lo-$hi';
    case 'notes':
      final parts = <String>[
        if (t.reason.trim().isNotEmpty) t.reason.trim(),
        if (t.notes.trim().isNotEmpty && t.notes.trim() != t.reason.trim()) t.notes.trim(),
        if (t.profile.isNotEmpty) t.profile,
        if (t.scale != null && (t.scale! - 1).abs() > 0.001) '${(t.scale! * 100).round()}%',
      ];
      return parts.join(' · ');
    case 'by':
      return t.enteredBy;
  }
  return '';
}

class _TreatmentLogScreenState extends State<TreatmentLogScreen> {
  int _days = 7; // 0 = custom range
  DateTimeRange? _range;
  Future<List<Treatment>>? _future;
  final Set<String> _kinds = {'carbs', 'bolus', 'auto', 'basal', 'preset', 'profile', 'device', 'other'};
  final Set<String> _cols = {'date', 'time', 'type', 'insulin', 'carbs', 'rate', 'duration', 'notes'};
  bool _busy = false;

  (DateTime, DateTime) get _period {
    final now = DateTime.now();
    if (_days == 0 && _range != null) {
      return (_range!.start, DateTime(_range!.end.year, _range!.end.month, _range!.end.day + 1));
    }
    return (DateTime(now.year, now.month, now.day - (_days - 1)), now);
  }

  void _load() {
    final (a, b) = _period;
    _future = app.client.treatmentsBetween(a, b).then((l) => l.where((t) => !t.t.isBefore(a) && t.t.isBefore(b)).toList());
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<Treatment> _filtered(List<Treatment> all) =>
      all.where((t) => tlKindsOf(t).any(_kinds.contains)).toList()..sort((a, b) => b.t.compareTo(a.t));

  List<String> get _colOrder => tlColumns.keys.where(_cols.contains).toList();

  String _fileBase() {
    final (a, b) = _period;
    final end = b.subtract(const Duration(seconds: 1));
    return 'treatments_${a.year}-${two(a.month)}-${two(a.day)}_${end.year}-${two(end.month)}-${two(end.day)}';
  }

  Future<void> _exportCsv(List<Treatment> rows) async {
    final mmol = app.mmol;
    String q(String v) => v.contains(RegExp(r'[",\n]')) ? '"${v.replaceAll('"', '""')}"' : v;
    final cols = _colOrder;
    final b = StringBuffer()..writeln(cols.map((c) => q(tlColumns[c]! + (c == 'target' ? ' (${unitLabel(mmol)})' : ''))).join(','));
    for (final t in rows.reversed) {
      b.writeln(cols.map((c) => q(tlCell(t, c, mmol))).join(','));
    }
    // With a BOM so Excel reads accents and symbols correctly.
    final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(b.toString())]);
    final name = '${_fileBase()}.csv';
    await Share.shareXFiles([XFile.fromData(bytes, mimeType: 'text/csv', name: name)], fileNameOverrides: [name], subject: name);
  }

  Future<void> _exportPdf(List<Treatment> rows) async {
    final mmol = app.mmol;
    final cols = _colOrder;
    final (a, b) = _period;
    final end = b.subtract(const Duration(seconds: 1));
    String clean(String s) => s.replaceAll('·', '-').replaceAll('–', '-');
    final doc = pw.Document(title: 'Treatment log');
    final totals = _totals(rows);
    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.letter.landscape, margin: const pw.EdgeInsets.all(24)),
      footer: (c) => pw.Row(children: [
        pw.Expanded(child: pw.Text('Monitor Glucose - treatment log', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700))),
        pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
      ]),
      build: (_) => [
        pw.Text('Treatment log', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.Text('${a.year}-${two(a.month)}-${two(a.day)} to ${end.year}-${two(end.month)}-${two(end.day)}   ·   '
            '${_kinds.length == tlKinds.length ? 'all treatments' : _kinds.map((k) => tlKinds[k]).join(', ')}', style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 4),
        pw.Text(clean(totals), style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 8),
        pw.TableHelper.fromTextArray(
          headers: cols.map((c) => tlColumns[c]!).toList(),
          data: [for (final t in rows.reversed) cols.map((c) => clean(tlCell(t, c, mmol))).toList()],
          headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 8),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColors.grey300, width: 0.5)),
        ),
      ],
    ));
    final bytes = await doc.save();
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: _fileBase());
  }

  String _totals(List<Treatment> rows) {
    var carbs = 0.0, bolus = 0.0, auto = 0.0;
    var basalU = 0.0;
    for (final t in rows) {
      carbs += t.carbs ?? 0;
      if (t.type == 'Temp Basal') {
        basalU += (t.absolute ?? 0) * (t.duration ?? 0) / 60;
      } else if ((t.insulin ?? 0) > 0) {
        if (t.isSmb) {
          auto += t.insulin!;
        } else {
          bolus += t.insulin!;
        }
      }
    }
    return '${rows.length} treatments · carbs ${carbs.round()} g · boluses ${_num(bolus, dec: 1)} U'
        '${auto > 0 ? ' · automatic ${_num(auto, dec: 1)} U' : ''}'
        '${_kinds.contains('basal') && basalU > 0 ? ' · temp basals as set ${_num(basalU, dec: 1)} U (if run in full)' : ''}';
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final mmol = app.mmol;
    return Scaffold(
      appBar: AppBar(title: const Text('Treatment log')),
      body: FutureBuilder<List<Treatment>>(
        future: _future,
        builder: (context, snap) {
          final rows = snap.hasData ? _filtered(snap.data!) : const <Treatment>[];
          final cols = _colOrder;
          return ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 30), children: [
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final d in [1, 7, 14, 30, 90])
                ChoiceChip(
                  label: Text(d == 1 ? 'Today' : '${d}d'),
                  selected: _days == d,
                  onSelected: (_) => setState(() {
                    _days = d;
                    _load();
                  }),
                ),
              ChoiceChip(
                label: Text(_days == 0 && _range != null
                    ? '${_range!.start.month}/${_range!.start.day}–${_range!.end.month}/${_range!.end.day}'
                    : 'Dates…'),
                selected: _days == 0,
                onSelected: (_) async {
                  final now = DateTime.now();
                  final r = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(now.year - 3),
                    lastDate: now,
                    initialDateRange: _range ?? DateTimeRange(start: now.subtract(const Duration(days: 6)), end: now),
                  );
                  if (r != null) {
                    setState(() {
                      _range = r;
                      _days = 0;
                      _load();
                    });
                  }
                },
              ),
            ]),
            const SizedBox(height: 12),
            const Text('Show', style: TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final k in tlKinds.entries)
                FilterChip(
                  label: Text(k.value),
                  selected: _kinds.contains(k.key),
                  onSelected: (v) => setState(() => v ? _kinds.add(k.key) : _kinds.remove(k.key)),
                ),
            ]),
            const SizedBox(height: 12),
            const Text('Columns', style: TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final c in tlColumns.entries)
                FilterChip(
                  label: Text(c.value),
                  selected: _cols.contains(c.key),
                  onSelected: (v) => setState(() {
                    if (v) {
                      _cols.add(c.key);
                    } else if (_cols.length > 1) {
                      _cols.remove(c.key);
                    }
                  }),
                ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: rows.isEmpty || _busy ? null : () => _run(() => _exportCsv(rows)),
                  icon: const Icon(Icons.table_view_outlined),
                  label: const Text('Export spreadsheet (CSV)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: rows.isEmpty || _busy ? null : () => _run(() => _exportPdf(rows)),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('PDF / print'),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            if (snap.connectionState != ConnectionState.done)
              const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
            else if (snap.hasError)
              Text(snap.error.toString(), style: const TextStyle(color: kAmber))
            else ...[
              Text(_totals(rows), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              if (rows.isEmpty)
                const Text('Nothing in this period with these choices.', style: TextStyle(color: kMuted))
              else
                Container(
                  decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingRowHeight: 34,
                      dataRowMinHeight: 26,
                      dataRowMaxHeight: 30,
                      columnSpacing: 16,
                      horizontalMargin: 10,
                      headingTextStyle: const TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.w600),
                      dataTextStyle: kMono.copyWith(fontSize: 12, color: kText),
                      columns: [
                        for (final c in cols)
                          DataColumn(
                            label: Text(c == 'target' ? '${tlColumns[c]} (${unitLabel(mmol)})' : tlColumns[c]!),
                            numeric: const {'insulin', 'carbs', 'rate', 'duration'}.contains(c),
                          ),
                      ],
                      rows: [
                        for (final t in rows.take(1000)) DataRow(cells: [for (final c in cols) DataCell(Text(tlCell(t, c, mmol)))]),
                      ],
                    ),
                  ),
                ),
              if (rows.length > 1000)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Showing the newest 1,000 of ${rows.length}. The export has them all.', style: const TextStyle(color: kMuted, fontSize: 12)),
                ),
            ],
          ]);
        },
      ),
    );
  }
}
