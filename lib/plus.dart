import 'package:flutter/foundation.dart' show kIsWeb;

/// True in Monitor Glucose Plus (built with --dart-define=PLUS=true): the
/// version you build yourself on GitHub, with Loop remote commands.
const bool kPlus = bool.fromEnvironment('PLUS');

const String kAppName = kPlus ? 'Monitor Glucose Plus' : 'Monitor Glucose';

/// Loop remote commands: in the Plus apps and in the web version (not in the
/// regular store apps).
const bool kRemote = kPlus || kIsWeb;
