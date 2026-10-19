import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:local_auth/local_auth.dart';

/// Asks for the phone's lock (PIN, pattern, Face ID / Touch ID / fingerprint)
/// before a command goes to Loop. Returns why it failed, or null when the
/// person was confirmed. In a browser there is no phone lock: the site's API
/// secret protects the commands there.
Future<String?> confirmDeviceLock(String reason) async {
  if (kIsWeb) return null;
  final auth = LocalAuthentication();
  try {
    if (!await auth.isDeviceSupported()) {
      return 'This phone has no screen lock. Set a PIN or code in the phone\'s settings to send commands to Loop.';
    }
    final ok = await auth.authenticate(
      localizedReason: reason,
      options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
    );
    return ok ? null : 'Not confirmed: nothing was sent.';
  } catch (e) {
    return 'The phone lock could not be checked ($e): nothing was sent.';
  }
}
