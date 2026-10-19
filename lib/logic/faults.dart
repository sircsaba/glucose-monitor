// Works out WHY readings or loops are late, for the flashing message on the
// top line of the home screen ("No Internet", "Libre connection down"...).
//
// Inputs come from the app itself (could it reach its site? is the internet up?)
// and, with your own Monitor Glucose server, from its /api/v1/health report:
// the LibreLinkUp job, the newest reading and loop there, the main Nightscout,
// and whether Loop is reading its glucose from that server (backup source).

/// The server's /api/v1/health report (null fields = not known).
class Health {
  final DateTime? serverTime;
  final String? feedProblem;
  final bool libreConfigured;
  final DateTime? libreLastRun;
  final bool libreOk;
  final DateTime? cgmLast;
  final DateTime? loopLast;
  final bool loopCgmFromHere;
  final bool mainConfigured;
  final String mainHost;
  final bool? mainReachable;
  final DateTime? mainCgmLast;
  final DateTime? mainLoopLast;

  const Health({
    this.serverTime,
    this.feedProblem,
    this.libreConfigured = false,
    this.libreLastRun,
    this.libreOk = true,
    this.cgmLast,
    this.loopLast,
    this.loopCgmFromHere = false,
    this.mainConfigured = false,
    this.mainHost = '',
    this.mainReachable,
    this.mainCgmLast,
    this.mainLoopLast,
  });

  static DateTime? _ms(dynamic v) => v is num && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
  static DateTime? _s(dynamic v) => v is num && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000) : null;

  static Health? fromJson(dynamic j) {
    if (j is! Map) return null;
    final libre = j['libre'];
    final main = j['main'];
    return Health(
      serverTime: _ms(j['serverTime']),
      feedProblem: j['feedProblem'] is String && (j['feedProblem'] as String).isNotEmpty ? j['feedProblem'] as String : null,
      libreConfigured: libre is Map,
      libreLastRun: libre is Map ? _s(libre['lastRun']) : null,
      libreOk: libre is Map ? libre['ok'] == true : true,
      cgmLast: _ms(j['cgmLast']),
      loopLast: _ms(j['loopLast']),
      loopCgmFromHere: j['loopCgmFromHere'] == true,
      mainConfigured: main is Map,
      mainHost: main is Map ? (main['host'] ?? '').toString() : '',
      mainReachable: main is Map ? main['reachable'] == true : null,
      mainCgmLast: main is Map ? _ms(main['cgmLast']) : null,
      mainLoopLast: main is Map ? _ms(main['loopLast']) : null,
    );
  }
}

/// What the top line shows: a fault (flashing) and/or that Loop uses the backup.
class FaultStatus {
  final String? fault;
  final bool onBackup;
  const FaultStatus(this.fault, this.onBackup);
  bool get isEmpty => fault == null && !onBackup;
}

/// [lateMin]: minutes without a new reading or loop that count as a fault.
/// [siteError]: the app could not get data from its site at all.
/// [internetUp]: result of the internet check (null = not checked).
/// [siteName]: the site's host, for "bg.example.com not answering".
FaultStatus diagnose({
  required DateTime now,
  required int lateMin,
  required bool siteError,
  bool? internetUp,
  String siteName = 'Glucose server',
  DateTime? lastReading,
  DateTime? lastLoop,
  Health? health,
}) {
  final onBackup = health?.loopCgmFromHere ?? false;
  bool late(DateTime? t) => t == null || now.difference(t).inSeconds >= lateMin * 60;
  bool fresh(DateTime? t) => !late(t);

  if (siteError) {
    if (internetUp == false) return FaultStatus('No Internet', onBackup);
    return FaultStatus('$siteName down', onBackup);
  }

  final h = health;
  final cgmLate = late(lastReading);
  // Loop uploads to both servers, and one can be a minute or two behind the
  // other: Loop is late only when NEITHER has a recent loop.
  final mainLoop = h != null && h.mainConfigured ? h.mainLoopLast : null;
  final newestLoop = [lastLoop, mainLoop].whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
  // No loop data at all (no loop on this site): nothing to check.
  final loopLate = newestLoop != null && late(newestLoop);
  // Loop fine on the main Nightscout, but nothing reached this server for a
  // long time (twice the limit): its upload here has stopped.
  final uploadStopped = !loopLate && mainLoop != null && lastLoop != null &&
      now.difference(lastLoop).inSeconds >= 2 * lateMin * 60;
  if (!cgmLate && !loopLate && !uploadStopped) return FaultStatus(null, onBackup);

  String? fault;

  if (cgmLate) {
    if (h != null && h.libreConfigured) {
      final jobIdle = h.libreLastRun == null || now.difference(h.libreLastRun!).inMinutes >= 3;
      if (!h.libreOk || h.feedProblem != null) {
        fault = 'Libre connection down';
      } else if (jobIdle) {
        fault = 'Libre job stopped';
      } else {
        // The job logs in and asks every minute, but LibreView has nothing new.
        fault = 'No new Libre data';
      }
    } else if (h != null && h.feedProblem != null) {
      fault = 'Reading feed down';
    } else {
      fault = 'No CGM data';
    }
  }

  if (fault == null && loopLate) {
    if (h != null && h.mainConfigured && !onBackup) {
      final main = h.mainHost.isEmpty ? 'Nightscout' : h.mainHost;
      if (h.mainReachable == false) {
        fault = '$main down';
      } else if (late(h.mainCgmLast) && fresh(h.cgmLast)) {
        // Readings reach this server but not the main Nightscout: the uploader
        // to Nightscout (Google VPS / LibreLinkUp) has stopped.
        fault = '$main: no readings (VPS)';
      }
    }
    fault ??= 'Loop not looping';
  }
  if (fault == null && uploadStopped) fault = 'Loop not uploading here';

  return FaultStatus(fault, onBackup);
}
