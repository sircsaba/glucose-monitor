import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/logic/faults.dart';

void main() {
  final now = DateTime(2026, 10, 17, 12, 0);
  DateTime ago(int min) => now.subtract(Duration(minutes: min));

  Health h({
    bool libre = true,
    bool libreOk = true,
    int? libreRunAgo = 0,
    String? feedProblem,
    int? cgm = 1,
    bool backup = false,
    bool hasMain = true,
    bool? mainUp = true,
    int? mainCgm = 1,
    int? mainLoop = 2,
  }) =>
      Health(
        libreConfigured: libre,
        libreOk: libreOk,
        libreLastRun: libreRunAgo == null ? null : ago(libreRunAgo),
        feedProblem: feedProblem,
        cgmLast: cgm == null ? null : ago(cgm),
        loopCgmFromHere: backup,
        mainConfigured: hasMain,
        mainHost: 'nsval.mooo.com',
        mainReachable: mainUp,
        mainCgmLast: mainCgm == null ? null : ago(mainCgm),
        mainLoopLast: mainLoop == null ? null : ago(mainLoop),
      );

  FaultStatus run({bool siteError = false, bool? net, int? reading = 2, int? loop = 3, Health? health}) => diagnose(
        now: now,
        lateMin: 7,
        siteError: siteError,
        internetUp: net,
        siteName: 'bg.inforap.com',
        lastReading: reading == null ? null : ago(reading),
        lastLoop: loop == null ? null : ago(loop),
        health: health,
      );

  test('all fine: nothing shown', () {
    final s = run(health: h());
    expect(s.fault, isNull);
    expect(s.onBackup, isFalse);
    expect(s.isEmpty, isTrue);
  });

  test('6 minutes is not late yet, 7 is', () {
    expect(run(reading: 6, health: h()).fault, isNull);
    expect(run(reading: 7, health: h()).fault, isNotNull);
  });

  test('site unreachable and internet down: No Internet', () {
    expect(run(siteError: true, net: false).fault, 'No Internet');
  });

  test('site unreachable but internet up: site down', () {
    expect(run(siteError: true, net: true).fault, 'bg.inforap.com down');
  });

  test('late reading with LibreLinkUp error: Libre connection down', () {
    expect(run(reading: 12, health: h(libreOk: false)).fault, 'Libre connection down');
    expect(run(reading: 12, health: h(feedProblem: 'LibreLinkUp: accept the new terms')).fault, 'Libre connection down');
  });

  test('late reading, Libre job not running', () {
    expect(run(reading: 12, health: h(libreRunAgo: 5)).fault, 'Libre job stopped');
  });

  test('late reading, job fine but LibreView has nothing new', () {
    expect(run(reading: 12, health: h()).fault, 'No new Libre data');
  });

  test('reading problems come first even when Loop is late too', () {
    expect(run(reading: 12, loop: 12, health: h(libreOk: false)).fault, 'Libre connection down');
  });

  test('late loop, main Nightscout down', () {
    expect(run(loop: 12, health: h(mainUp: false, mainCgm: null, mainLoop: null)).fault, 'nsval.mooo.com down');
  });

  test('late loop, Nightscout gets no readings but this server does: VPS', () {
    expect(run(loop: 12, health: h(mainCgm: 15, mainLoop: 15)).fault, 'nsval.mooo.com: no readings (VPS)');
  });

  test('this server a few minutes behind Nightscout: no alarm', () {
    // WHC can get Loop's upload 1-2 minutes after Nightscout.
    expect(run(loop: 8, health: h(mainLoop: 1)).fault, isNull);
    expect(run(loop: 12, health: h(mainLoop: 2)).fault, isNull);
  });

  test('nothing reached this server for twice the limit, Nightscout fine: upload to here', () {
    expect(run(loop: 14, health: h(mainLoop: 2)).fault, 'Loop not uploading here');
  });

  test('late loop, everything else fine: Loop not looping', () {
    expect(run(loop: 12, health: h(mainLoop: 12)).fault, 'Loop not looping');
  });

  test('on backup: Nightscout being down is not blamed', () {
    final s = run(loop: 12, health: h(backup: true, mainUp: false, mainCgm: null, mainLoop: null));
    expect(s.fault, 'Loop not looping');
    expect(s.onBackup, isTrue);
  });

  test('on backup, all fine: only the backup label', () {
    final s = run(health: h(backup: true));
    expect(s.fault, isNull);
    expect(s.onBackup, isTrue);
    expect(s.isEmpty, isFalse);
  });

  test('plain Nightscout site (no health report)', () {
    expect(run(reading: 12).fault, 'No CGM data');
    expect(run(loop: 12).fault, 'Loop not looping');
  });

  test('site without loop data: only readings are checked', () {
    expect(run(loop: null, health: h()).fault, isNull);
  });

  test('health report parsed from the server JSON', () {
    final p = Health.fromJson({
      'serverTime': 1792272967765,
      'feedProblem': null,
      'libre': {'lastRun': 1792272952, 'ok': true, 'fails': 0, 'error': null},
      'cgmLast': 1792272907000,
      'loopLast': null,
      'loopCgmFromHere': true,
      'main': {'checked': 1792272967, 'host': 'nsval.mooo.com', 'reachable': false, 'cgmLast': null, 'loopLast': null},
    })!;
    expect(p.libreConfigured, isTrue);
    expect(p.libreLastRun, DateTime.fromMillisecondsSinceEpoch(1792272952000));
    expect(p.loopCgmFromHere, isTrue);
    expect(p.mainConfigured, isTrue);
    expect(p.mainReachable, isFalse);
    expect(p.mainHost, 'nsval.mooo.com');
    expect(Health.fromJson('not json'), isNull);
    expect(Health.fromJson({'main': null})!.mainConfigured, isFalse);
  });
}
