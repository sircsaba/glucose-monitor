import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Time-based one-time password (RFC 6238), from the otpauth:// link in Loop's
/// QR code (Loop › Settings › Services › Nightscout › One-Time Password).
class Totp {
  final List<int> secret;
  final int digits;
  final int period; // seconds
  final String algorithm; // SHA1, SHA256, SHA512
  final String label;
  Totp(this.secret, {this.digits = 6, this.period = 30, this.algorithm = 'SHA1', this.label = ''});

  /// Reads an otpauth://totp/... link; null if it is not one.
  static Totp? parse(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || u.scheme != 'otpauth' || u.host.toLowerCase() != 'totp') return null;
    final s = u.queryParameters['secret'];
    if (s == null || s.isEmpty) return null;
    final key = base32Decode(s);
    if (key == null || key.isEmpty) return null;
    return Totp(
      key,
      digits: int.tryParse(u.queryParameters['digits'] ?? '') ?? 6,
      period: int.tryParse(u.queryParameters['period'] ?? '') ?? 30,
      algorithm: (u.queryParameters['algorithm'] ?? 'SHA1').toUpperCase(),
      label: Uri.decodeComponent(u.path.replaceFirst('/', '')),
    );
  }

  /// The code for [at] (now by default).
  String code([DateTime? at]) {
    final t = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 ~/ period;
    // Two 32-bit halves: 64-bit access is not available in the web version.
    final msg = ByteData(8)
      ..setUint32(0, t ~/ 4294967296)
      ..setUint32(4, t % 4294967296);
    final h = switch (algorithm) {
      'SHA256' => Hmac(sha256, secret),
      'SHA512' => Hmac(sha512, secret),
      _ => Hmac(sha1, secret),
    };
    final mac = h.convert(msg.buffer.asUint8List()).bytes;
    final o = mac.last & 0x0f;
    final bin = ((mac[o] & 0x7f) << 24) | (mac[o + 1] << 16) | (mac[o + 2] << 8) | mac[o + 3];
    var mod = 1;
    for (var i = 0; i < digits; i++) {
      mod *= 10;
    }
    return (bin % mod).toString().padLeft(digits, '0');
  }

  /// Seconds until the code changes.
  int secondsLeft([DateTime? at]) => period - ((at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000) % period;
}

List<int>? base32Decode(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final s = input.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final ch in s.split('')) {
    final v = alphabet.indexOf(ch);
    if (v < 0) return null;
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
  }
  return out;
}
