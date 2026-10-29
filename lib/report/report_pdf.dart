import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Canvas, Color, CustomPainter, Offset, Paint, Size;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../logic/glucose.dart';
import '../logic/report.dart';
import '../state/app_state.dart';
import '../ui/report_charts.dart';
import '../ui/reports_screen.dart';
import '../ui/nutrition_tab.dart';

/// Draws one of the report charts into a PNG (white background, print colours).
Future<Uint8List> _png(CustomPainter p, double w, double h, {double scale = 2.5}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.scale(scale);
  c.drawRect(Offset.zero & Size(w, h), Paint()..color = const Color(0xFFFFFFFF));
  p.paint(c, Size(w, h));
  final img = await rec.endRecording().toImage((w * scale).ceil(), (h * scale).ceil());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// The PDF fonts only know Western characters: replace the few others we use.
String _t(String s) => s.replaceAll('–', '-').replaceAll('÷', '/').replaceAll('≤', '<=').replaceAll('≥', '>=').replaceAll('→', '->');

PdfColor _pc(Color c) => PdfColor.fromInt(c.toARGB32());

/// Builds the chosen reports (0 summary, 1 day to day, 2 daily stats,
/// 3 distribution) and opens the print / save-as-PDF dialog.
Future<void> printReport(ReportData d, Set<int> which) async {
  final bytes = await buildReportPdf(d, which);
  final day = '${d.to.year}-${two(d.to.month)}-${two(d.to.day)}';
  await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'Glucose report $day');
}

Future<Uint8List> buildReportPdf(ReportData d, Set<int> which) async {
  final mmol = app.mmol;
  final s = app.settings;
  final tightColor = Color(s.integer('ttirColor'));
  final site = s.str('siteName').isNotEmpty ? s.str('siteName') : 'Monitor Glucose';
  final period = '${dayTitle(d.from)}  to  ${dayTitle(d.to)}';
  final doc = pw.Document(title: 'Glucose report', author: 'Monitor Glucose');
  const light = ChartTheme.light;

  final small = pw.TextStyle(fontSize: 8, color: PdfColors.grey700);
  final body = const pw.TextStyle(fontSize: 9);
  final bold = pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold);

  pw.Widget header(String title) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Row(children: [
          pw.Expanded(child: pw.Text(_t(title), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold))),
          pw.Text(_t(site), style: small),
        ]),
        pw.Text(_t('$period  ·  glucose in ${unitLabel(mmol)}'), style: small),
        pw.SizedBox(height: 8),
      ]);

  pw.Widget table(List<List<String>> rows, {Set<int> left = const {0}, double font = 8}) => pw.TableHelper.fromTextArray(
        headers: rows.first.map(_t).toList(),
        data: rows.skip(1).map((r) => r.map(_t).toList()).toList(),
        headerStyle: pw.TextStyle(fontSize: font, fontWeight: pw.FontWeight.bold),
        cellStyle: pw.TextStyle(fontSize: font),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
        cellAlignments: {for (var i = 0; i < rows.first.length; i++) i: left.contains(i) ? pw.Alignment.centerLeft : pw.Alignment.centerRight},
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColors.grey300, width: 0.5)),
      );

  pw.Widget legend(List<PieSlice> slices) {
    final total = slices.fold(0.0, (a, x) => a + x.value);
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      for (final x in slices)
        if (x.value > 0)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
            child: pw.Row(children: [
              pw.Container(width: 8, height: 8, color: _pc(x.color)),
              pw.SizedBox(width: 4),
              pw.Text(_t('${x.label}  ${total > 0 ? (x.value / total * 100).round() : 0}%'), style: body),
            ]),
          ),
    ]);
  }

  pw.Widget footer(pw.Context ctx) => pw.Row(children: [
        pw.Expanded(child: pw.Text('Monitor Glucose  ·  for information only, not for treatment decisions', style: small)),
        pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: small),
      ]);

  final pageTheme = pw.PageTheme(pageFormat: PdfPageFormat.letter, margin: const pw.EdgeInsets.all(28));

  // ---------- summary
  if (which.contains(0) && d.bg != null) {
    final b = d.bg!;
    final tirPie = await _png(PiePainter(rangeSlices(b, tightColor, d.ttirOn), theme: light), 140, 140);
    final insPie = await _png(
        PiePainter(insulinSlices(d.ins), center: '${fmtU((d.avgTdd * 10).round() / 10)} U/d', theme: light), 140, 140);
    final agp = await _png(AgpPainter(d.agp, d.lo, d.hi, mmol, tightHi: d.ttirOn ? d.tightHi : null, tightColor: tightColor, theme: light), 520, 200);
    final stats = summaryStats(d, mmol);
    doc.addPage(pw.MultiPage(
      pageTheme: pageTheme,
      footer: footer,
      build: (_) => [
        header('Summary'),
        pw.Row(children: [
          pw.Text('Time in range ', style: body),
          pw.Text('${(b.inRange * 100).round()}%', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.green700)),
          if (d.ttirOn) ...[
            pw.SizedBox(width: 20),
            pw.Text(_t('Time in tight range (${fmtBg(d.lo, mmol)}-${fmtBg(d.tightHi, mmol)}) '), style: body),
            pw.Text('${(b.tight * 100).round()}%', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.green700)),
          ],
        ]),
        pw.SizedBox(height: 10),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          pw.Image(pw.MemoryImage(tirPie), width: 110, height: 110),
          pw.SizedBox(width: 8),
          legend(rangeSlices(b, tightColor, d.ttirOn)),
          pw.SizedBox(width: 24),
          pw.Image(pw.MemoryImage(insPie), width: 110, height: 110),
          pw.SizedBox(width: 8),
          legend(insulinSlices(d.ins)),
        ]),
        pw.SizedBox(height: 12),
        table([
          ['Figure', 'Value', 'Note'],
          for (final x in stats) [x.$1, x.$2, x.$3 ?? ''],
        ], left: const {0, 2}, font: 9),
        pw.SizedBox(height: 12),
        pw.Text('Profile by time of day (median, 25-75% and 5-95%)', style: bold),
        pw.SizedBox(height: 4),
        pw.Image(pw.MemoryImage(agp)),
      ],
    ));
  }

  // ---------- day to day: two days per page
  if (which.contains(1)) {
    final blocks = <pw.Widget>[];
    for (final day in d.days) {
      final img = await _png(
        DayChartPainter(
          day: day.day,
          entries: day.entries,
          treatments: d.treatments,
          profiles: d.profiles,
          lo: d.lo,
          hi: d.hi,
          tightHi: d.ttirOn ? d.tightHi : null,
          tightColor: tightColor,
          mmol: mmol,
          theme: light,
        ),
        700,
        250,
        scale: 2,
      );
      final totals = dayTotals(day, mmol);
      blocks.add(pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 14),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Row(children: [
            pw.Expanded(child: pw.Text(dayTitle(day.day), style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold))),
            if (day.bg != null)
              pw.Text(
                  d.ttirOn
                      ? 'TIR ${(day.bg!.inRange * 100).round()}%   TTIR ${(day.bg!.tight * 100).round()}%'
                      : 'TIR ${(day.bg!.inRange * 100).round()}%',
                  style: pw.TextStyle(fontSize: 10, color: PdfColors.green700, fontWeight: pw.FontWeight.bold)),
          ]),
          pw.SizedBox(height: 3),
          pw.Image(pw.MemoryImage(img)),
          pw.SizedBox(height: 3),
          pw.Wrap(spacing: 12, runSpacing: 2, children: [
            for (final kv in totals)
              pw.RichText(
                  text: pw.TextSpan(children: [
                pw.TextSpan(text: _t('${kv.$1} '), style: small),
                pw.TextSpan(text: _t(kv.$2), style: bold),
              ])),
          ]),
        ]),
      ));
    }
    doc.addPage(pw.MultiPage(pageTheme: pageTheme, footer: footer, build: (_) => [header('Day to day'), ...blocks]));
  }

  // ---------- daily stats (landscape: many columns)
  if (which.contains(2)) {
    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.letter.landscape, margin: const pw.EdgeInsets.all(24)),
      footer: footer,
      build: (_) => [
        header('Daily stats'),
        table(dailyStatsRows(d, mmol), font: 7.5),
        pw.SizedBox(height: 6),
        pw.Text('Insulin in units, carbs in grams. V.low under ${fmtBg(54, mmol)}, V.high over ${fmtBg(250, mmol)}.', style: small),
      ],
    ));
  }

  // ---------- distribution
  if (which.contains(3) && d.bg != null) {
    final colors = rangeColorList(tightColor, d.ttirOn);
    final hourly = await _png(HourlyPainter(d.hourly, colors, theme: light), 520, 190);
    final names = ['Very low', 'Low', d.ttirOn ? 'Tight range' : 'In range', if (d.ttirOn) 'Range above tight', 'High', 'Very high'];
    final legendColors = [colors[0], colors[1], colors[2], if (d.ttirOn) colors[3], colors[4], colors[5]];
    doc.addPage(pw.MultiPage(
      pageTheme: pageTheme,
      footer: footer,
      build: (_) => [
        header('Distribution'),
        table(distributionRows(d, mmol), left: const {0, 1}, font: 9),
        pw.SizedBox(height: 14),
        pw.Text('Time in each range by hour of day', style: bold),
        pw.SizedBox(height: 4),
        pw.Image(pw.MemoryImage(hourly)),
        pw.SizedBox(height: 4),
        pw.Wrap(spacing: 10, children: [
          for (var i = 0; i < names.length; i++)
            pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
              pw.Container(width: 8, height: 8, color: _pc(legendColors[i])),
              pw.SizedBox(width: 3),
              pw.Text(names[i], style: small),
            ]),
        ]),
        pw.SizedBox(height: 14),
        table([
          ['Figure', 'Value'],
          for (final kv in variabilityRows(d, mmol)) [kv.$1, kv.$2],
        ], left: const {0, 1}, font: 9),
      ],
    ));
  }

  // ---------- nutrition
  if (which.contains(4)) {
    final r = d.nutrition;
    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.letter.landscape, margin: const pw.EdgeInsets.all(24)),
      footer: footer,
      build: (_) => [
        header('Nutrition'),
        pw.Text(_t('Carbs per day ${r.avgCarbs.round()} g (all carb entries). Calories, protein and fat from meals on the Food screen: '
            '${r.daysWithMeals} of ${r.days.length} days.'), style: body),
        pw.SizedBox(height: 8),
        table(nutritionDayRows(r), font: 8),
        pw.SizedBox(height: 12),
        pw.Text('Meals that raised glucose the most (reading when eating to the highest in the next 3 hours; * other carbs within 2 hours)', style: bold),
        pw.SizedBox(height: 4),
        if (r.meals.isNotEmpty) table(mealRiseRows(r, mmol), left: const {0, 1}, font: 8) else pw.Text('No meals from the Food screen in this period.', style: small),
        if (r.foods.isNotEmpty) ...[
          pw.SizedBox(height: 12),
          pw.Text('Foods by average rise', style: bold),
          pw.SizedBox(height: 4),
          table(foodRiseRows(r, mmol), font: 8),
        ],
      ],
    ));
  }

  return doc.save();
}
