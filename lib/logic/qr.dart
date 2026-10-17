import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Reads the text of a QR code in a photo or screenshot; null if none found.
String? readQr(Uint8List bytes) {
  var image = img.decodeImage(bytes);
  if (image == null) return null;
  // Big photos are slow to scan and no more readable.
  if (image.width > 1400 || image.height > 1400) {
    image = image.width >= image.height ? img.copyResize(image, width: 1400) : img.copyResize(image, height: 1400);
  }
  final pixels = image.convert(numChannels: 4).getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List();
  final source = RGBLuminanceSource(image.width, image.height, pixels);
  for (final binarizer in [HybridBinarizer(source), GlobalHistogramBinarizer(source)]) {
    try {
      return QRCodeReader().decode(BinaryBitmap(binarizer)).text;
    } catch (_) {}
  }
  return null;
}
