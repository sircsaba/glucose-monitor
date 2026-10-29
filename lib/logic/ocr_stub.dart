import 'dart:typed_data';

bool get ocrAvailable => false;

Future<String?> readTextFromImage(String path) async => null;

Future<String?> readTextFromPdfPages(Uint8List pdf, {int maxPages = 8, void Function(int page)? onPage}) async => null;
