import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing_lib/common.dart';
import 'package:zxing_lib/zxing.dart';

const _formats = [
  BarcodeFormat.ean13,
  BarcodeFormat.ean8,
  BarcodeFormat.upcA,
  BarcodeFormat.upcE,
  BarcodeFormat.code128,
];

/// Reads a product barcode (EAN-13, UPC-A, EAN-8, UPC-E) in a photo; null if
/// none is found. Tries the photo as is and turned a quarter (a barcode shot
/// with the phone upright), at two sizes.
String? readBarcode(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final base = img.bakeOrientation(decoded);
  for (final width in [1600, 1000]) {
    var im = base.width > width ? img.copyResize(base, width: width) : base;
    for (var turn = 0; turn < 2; turn++) {
      final r = _read(im);
      if (r != null) return r;
      im = img.copyRotate(im, angle: 90);
    }
  }
  return null;
}

/// Same, for an image already in memory (also used by the tests).
String? readBarcodeImage(img.Image im) => _read(im);

String? _read(img.Image im) {
  final w = im.width, h = im.height;
  final lum = Uint8List(w * h);
  var i = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = im.getPixel(x, y);
      lum[i++] = ((p.r.toInt() + 2 * p.g.toInt() + p.b.toInt()) >> 2) & 0xff;
    }
  }
  final source = RGBLuminanceSource.orig(w, h, lum);
  final hints = const DecodeHint(possibleFormats: _formats, tryHarder: true);
  for (final bitmap in [BinaryBitmap(HybridBinarizer(source)), BinaryBitmap(GlobalHistogramBinarizer(source))]) {
    try {
      final text = MultiFormatReader().decode(bitmap, hints).text.trim();
      if (text.isNotEmpty) return normalizeBarcode(text);
    } catch (_) {}
  }
  return null;
}

/// Digits only; UPC-A (12) as EAN-13 (leading 0), as Open Food Facts stores it.
String normalizeBarcode(String s) {
  final d = s.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length == 12) return '0$d';
  return d;
}
