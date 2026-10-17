import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/logic/otp.dart';
import 'package:glucose_monitor/logic/profile.dart';

void main() {
  // RFC 6238 test vectors (secret "12345678901234567890", 8 digits, SHA1).
  test('TOTP matches the RFC test vectors', () {
    final t = Totp.parse('otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&algorithm=SHA1&period=30')!;
    expect(t.code(DateTime.fromMillisecondsSinceEpoch(59 * 1000, isUtc: true)), '94287082');
    expect(t.code(DateTime.fromMillisecondsSinceEpoch(1111111109 * 1000, isUtc: true)), '07081804');
    expect(t.code(DateTime.fromMillisecondsSinceEpoch(1234567890 * 1000, isUtc: true)), '89005924');
    expect(t.code(DateTime.fromMillisecondsSinceEpoch(20000000000 * 1000, isUtc: true)), '65353130');
  });

  test('Loop style link (6 digits)', () {
    final t = Totp.parse('otpauth://totp/Loop%20iPhone?algorithm=SHA1&digits=6&issuer=Loop&period=30&secret=JBSWY3DPEHPK3PXP');
    expect(t, isNotNull);
    expect(t!.code().length, 6);
    expect(t.label, 'Loop iPhone');
    expect(Totp.parse('https://example.com'), isNull);
  });

  test('Loop presets and device token from the profile', () {
    final p = parseProfiles([
      {
        'defaultProfile': 'Default',
        'startDate': '2026-10-17T00:00:00Z',
        'store': {'Default': {'basal': [], 'units': 'mg/dL'}},
        'loopSettings': {
          'deviceToken': 'abc',
          'bundleIdentifier': 'com.X.loopkit.Loop',
          'maximumBolus': 5,
          'overridePresets': [
            {'name': 'Exercise', 'symbol': '🏃', 'duration': 3600, 'insulinNeedsScaleFactor': 0.5, 'targetRange': [140, 160]},
            {'name': 'Sick', 'symbol': '🤒', 'duration': 0},
          ],
        },
      },
    ]).first;
    expect(p.isLoop, true);
    expect(p.deviceToken, 'abc');
    expect(p.maxBolus, 5);
    expect(p.presets.length, 2);
    expect(p.presets.first.durationMin, 60);
    expect(p.presets.first.label, '🏃 Exercise');
    expect(p.presets[1].durationMin, isNull);
  });
}
