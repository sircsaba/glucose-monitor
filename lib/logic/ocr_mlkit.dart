import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';

import 'package:printing/printing.dart';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

bool get ocrAvailable => Platform.isIOS || Platform.isAndroid;

/// The text of a recipe photo, block by block. Recipe cards often have the
/// ingredients in a left column and the steps on the right: blocks are read
/// column by column, top to bottom.
Future<String?> readTextFromImage(String path) async {
  if (!ocrAvailable) return null;
  final r = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final t = await r.processImage(InputImage.fromFilePath(path));
    if (t.blocks.isEmpty) return '';
    final right = t.blocks.map((b) => b.boundingBox.right).reduce((a, b) => a > b ? a : b);
    final left = t.blocks.map((b) => b.boundingBox.left).reduce((a, b) => a < b ? a : b);
    final mid = left + (right - left) / 2;
    // Two columns only when blocks clearly start on both halves and none spans the middle.
    final spans = t.blocks.where((b) => b.boundingBox.left < mid - 20 && b.boundingBox.right > mid + 20).length;
    final twoCols = spans <= t.blocks.length ~/ 5 && t.blocks.any((b) => b.boundingBox.left > mid);
    final blocks = [...t.blocks]
      ..sort((a, b) {
        if (twoCols) {
          final ca = a.boundingBox.left > mid ? 1 : 0, cb = b.boundingBox.left > mid ? 1 : 0;
          if (ca != cb) return ca.compareTo(cb);
        }
        return a.boundingBox.top.compareTo(b.boundingBox.top);
      });
    return blocks.map((b) => b.lines.map((l) => l.text).join('\n')).join('\n');
  } finally {
    await r.close();
  }
}

/// The text of a scanned PDF (pages that are pictures): each page is drawn as
/// an image on the phone and read like a photo. At most [maxPages] pages.
Future<String?> readTextFromPdfPages(Uint8List pdf, {int maxPages = 8, void Function(int page)? onPage}) async {
  if (!ocrAvailable) return null;
  final dir = await Directory.systemTemp.createTemp('mg_pdf');
  final out = StringBuffer();
  try {
    var n = 0;
    await for (final page in Printing.raster(pdf, dpi: 200)) {
      if (n >= maxPages) break;
      onPage?.call(++n);
      final f = File('${dir.path}/page$n.png');
      await f.writeAsBytes(await page.toPng());
      out.writeln(await readTextFromImage(f.path) ?? '');
    }
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
  return out.toString();
}
