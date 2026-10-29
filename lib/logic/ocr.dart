/// Reads the text in a photo on the phone itself (Google ML Kit, no internet,
/// no AI service). Not available in the web app: there the text is pasted.
export 'ocr_stub.dart' if (dart.library.io) 'ocr_mlkit.dart';
