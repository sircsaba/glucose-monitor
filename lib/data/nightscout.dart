import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../logic/food.dart';
import '../logic/profile.dart';

class NsException implements Exception {
  final String message;
  NsException(this.message);
  @override
  String toString() => message;
}

/// One glucose reading. [mg] is always mg/dL.
class Entry {
  final DateTime t;
  final double mg;
  final String direction;
  Entry(this.t, this.mg, this.direction);
}

class Treatment {
  final DateTime t;
  final String type;
  final double? insulin;
  final double? carbs;
  final double? absolute; // temp basal rate U/h
  final double? duration; // minutes
  final bool isSmb; // SMB, or a bolus the loop gave by itself (Loop: automatic)
  final String notes;
  final String profile; // Profile Switch: the profile's name
  final String enteredBy;
  // Presets: Loop "Temporary Override", Trio / AAPS "Temporary Target".
  final String reason;
  final double? targetLo; // mg/dL
  final double? targetHi;
  final double? scale; // Loop: insulin needs, 1 = 100 %
  final bool indefinite;
  Treatment({
    required this.t,
    required this.type,
    this.insulin,
    this.carbs,
    this.absolute,
    this.duration,
    this.isSmb = false,
    this.notes = '',
    this.profile = '',
    this.enteredBy = '',
    this.reason = '',
    this.targetLo,
    this.targetHi,
    this.scale,
    this.indefinite = false,
  });

  bool get isPreset => type == 'Temporary Override' || type == 'Temporary Target';
}

/// One line of your own server's event log (Settings › Logs).
class LogEvent {
  final int id;
  final DateTime t;
  final String kind; // cgm, push, loop, treatment, job
  final String msg;
  LogEvent(this.id, this.t, this.kind, this.msg);
}

/// Loop / pump status from the latest device status uploads.
class DeviceInfo {
  DateTime? loopTime;
  double? iob;
  double? cob;
  double? basal;
  double? basalMinLeft;
  DateTime? predStart;
  List<List<double>> predLines = [];
  double? reservoir;
  String? reservoirText; // e.g. "50+U" from Omnipod
  int? pumpBattery;
  double? pumpVolts; // some pumps send volts instead of percent
  int? phoneBattery;
  DateTime? pumpTime;

  /// Loop's override as of its last upload (devicestatus "override").
  bool overrideSeen = false;
  bool overrideActive = false;
  String overrideName = '';
  DateTime? overrideEnd; // null: until cancelled
  double? overrideMultiplier;
  double? recommendedBolus; // Loop's own suggestion (no new carbs)

  /// The prediction line drawn on the graph.
  List<double> get mainPrediction => predLines.isEmpty ? const [] : predLines.first;
}

double? _d(dynamic x) {
  if (x is num) return x.toDouble();
  if (x is String) return double.tryParse(x);
  return null;
}

DateTime? _time(dynamic x) {
  if (x is num) return DateTime.fromMillisecondsSinceEpoch(x.toInt());
  if (x is String && x.isNotEmpty) {
    try {
      return DateTime.parse(x).toLocal();
    } catch (_) {
      return null;
    }
  }
  return null;
}

class NightscoutClient {
  final String base;
  final String secret;
  final bool isApiSecret;

  NightscoutClient(String url, this.secret, this.isApiSecret) : base = normalize(url);

  static String normalize(String u) {
    var s = u.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Map<String, String> get _headers {
    final h = <String, String>{'Accept': 'application/json'};
    if (isApiSecret && secret.isNotEmpty) {
      h['api-secret'] = sha1.convert(utf8.encode(secret)).toString();
    }
    return h;
  }

  Uri _uri(String path, Map<String, String> q) {
    final qp = Map<String, String>.from(q);
    if (!isApiSecret && secret.isNotEmpty) qp['token'] = secret;
    final u = Uri.parse('$base$path');
    return qp.isEmpty ? u : u.replace(queryParameters: qp);
  }

  Future<dynamic> _get(String path, [Map<String, String> q = const {}]) async {
    http.Response? res;
    // One quiet retry: a request dropped on the way (Wi-Fi blip, many requests at
    // once after a settings change) should not show an error.
    for (var attempt = 0; res == null; attempt++) {
      try {
        res = await http.get(_uri(path, q), headers: _headers).timeout(const Duration(seconds: 25));
      } on TimeoutException {
        throw NsException('The site did not answer in time');
      } catch (e) {
        if (attempt >= 1) throw NsException('Cannot reach the site: $e');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    final http.Response r = res;
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw NsException('Not authorised: check the token or API secret');
    }
    if (r.statusCode != 200) throw NsException('The site answered with error ${r.statusCode}');
    try {
      return jsonDecode(r.body);
    } catch (_) {
      throw NsException('The site did not send data. Is this a Nightscout address?');
    }
  }

  /// A problem with the job that brings readings into your own server
  /// (e.g. LibreLinkUp asking to accept new terms); null when all is well or
  /// when the site does not report it (Nightscout).
  Future<String?> feedProblem() async {
    final s = await _get('/api/v1/status.json');
    if (s is Map && s['feedProblem'] is String && (s['feedProblem'] as String).isNotEmpty) return s['feedProblem'] as String;
    return null;
  }

  /// Your own server's health report (LibreLinkUp job, main Nightscout, backup
  /// use); null when the site has none (a plain Nightscout answers 404).
  Future<dynamic> health() async {
    try {
      final r = await http.get(_uri('/api/v1/health.json', const {}), headers: _headers).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
  }

  /// True when the internet answers (two well-known sites that allow web apps
  /// to ask), false when neither does. Used only after the site failed, to tell
  /// "No Internet" from "the site is down".
  static Future<bool> internetUp() async {
    const probes = ['https://dns.google/resolve?name=apple.com&type=A', 'https://api.github.com/zen'];
    for (final p in probes) {
      try {
        await http.get(Uri.parse(p)).timeout(const Duration(seconds: 6));
        return true;
      } catch (_) {}
    }
    return false;
  }

  /// Checks the address and token. Returns the site name.
  Future<String> test() async {
    final s = await _get('/api/v1/status.json');
    if (s is Map) {
      final settings = s['settings'];
      if (settings is Map && settings['customTitle'] != null) return settings['customTitle'].toString();
      return 'Nightscout';
    }
    throw NsException('Unexpected answer from the site');
  }

  Future<List<Entry>> entriesSince(DateTime since, {int count = 3000}) async {
    final j = await _get('/api/v1/entries/sgv.json', {
      'find[date][\$gte]': '${since.millisecondsSinceEpoch}',
      'count': '$count',
    });
    final out = <Entry>[];
    if (j is List) {
      for (final e in j) {
        if (e is! Map) continue;
        final mg = _d(e['sgv']);
        final ms = e['date'];
        if (mg == null || mg < 20 || ms is! num) continue;
        out.add(Entry(DateTime.fromMillisecondsSinceEpoch(ms.toInt()), mg, (e['direction'] ?? '').toString()));
      }
    }
    out.sort((a, b) => a.t.compareTo(b.t));
    return out;
  }

  /// Readings over a long period, a few days at a time (a sensor sending every
  /// minute gives 1,440 readings a day).
  Future<List<Entry>> entriesBetween(DateTime from, DateTime to) async {
    final out = <Entry>[];
    var a = from;
    while (a.isBefore(to)) {
      final b = a.add(const Duration(days: 5)).isAfter(to) ? to : a.add(const Duration(days: 5));
      final j = await _get('/api/v1/entries/sgv.json', {
        'find[date][\$gte]': '${a.millisecondsSinceEpoch}',
        'find[date][\$lt]': '${b.millisecondsSinceEpoch}',
        'count': '10000',
      });
      if (j is List) {
        for (final e in j) {
          if (e is! Map) continue;
          final mg = _d(e['sgv']);
          final ms = e['date'];
          if (mg == null || mg < 20 || ms is! num) continue;
          out.add(Entry(DateTime.fromMillisecondsSinceEpoch(ms.toInt()), mg, (e['direction'] ?? '').toString()));
        }
      }
      a = b;
    }
    out.sort((x, y) => x.t.compareTo(y.t));
    // The same reading twice (two sources a few seconds apart): keep one per minute.
    final dedup = <Entry>[];
    for (final e in out) {
      if (dedup.isEmpty || e.t.difference(dedup.last.t).inSeconds >= 30) dedup.add(e);
    }
    return dedup;
  }

  Treatment? _treatment(dynamic e) {
    if (e is! Map) return null;
    final t = _time(e['created_at']) ?? _time(e['mills']) ?? _time(e['date']);
    if (t == null) return null;
    return Treatment(
      t: t,
      type: (e['eventType'] ?? '').toString(),
      insulin: _d(e['insulin']),
      carbs: _d(e['carbs']),
      absolute: _d(e['absolute']) ?? _d(e['rate']),
      duration: _d(e['duration']),
      isSmb: e['isSMB'] == true || (e['type'] ?? '').toString() == 'SMB' || e['automatic'] == true,
      profile: (e['profile'] ?? e['profileName'] ?? '').toString(),
      enteredBy: (e['enteredBy'] ?? '').toString(),
      notes: (e['notes'] ?? '').toString(),
      reason: (e['reason'] ?? e['notes'] ?? '').toString(),
      targetLo: _presetTarget(e, true),
      targetHi: _presetTarget(e, false),
      scale: _d(e['insulinNeedsScaleFactor']),
      indefinite: (e['durationType'] ?? '').toString() == 'indefinite',
    );
  }

  /// Target range of a preset in mg/dL: Loop's correctionRange, or Trio's targetBottom / targetTop.
  double? _presetTarget(Map e, bool low) {
    final cr = e['correctionRange'];
    if (cr is List && cr.length == 2) return _d(cr[low ? 0 : 1]);
    final v = _d(e[low ? 'targetBottom' : 'targetTop']);
    if (v == null) return null;
    // Trio / AAPS may send mmol/L.
    final units = (e['units'] ?? '').toString().toLowerCase();
    return units.startsWith('mmol') || v < 30 ? v * 18.0182 : v;
  }

  Future<List<Treatment>> treatmentsSince(DateTime since, {int count = 1000, DateTime? until}) async {
    final j = await _get('/api/v1/treatments.json', {
      'find[created_at][\$gte]': since.toUtc().toIso8601String(),
      if (until != null) 'find[created_at][\$lt]': until.toUtc().toIso8601String(),
      'count': '$count',
    });
    final out = <Treatment>[];
    if (j is List) {
      for (final e in j) {
        final t = _treatment(e);
        if (t != null) out.add(t);
      }
    }
    out.sort((a, b) => a.t.compareTo(b.t));
    return out;
  }

  /// Treatments over a long period, a few days at a time (Loop logs a temp
  /// basal every 5 minutes, so one request could be cut short).
  Future<List<Treatment>> treatmentsBetween(DateTime from, DateTime to) async {
    final out = <Treatment>[];
    var a = from;
    while (a.isBefore(to)) {
      final b = a.add(const Duration(days: 3)).isAfter(to) ? to : a.add(const Duration(days: 3));
      out.addAll(await treatmentsSince(a, until: b, count: 5000));
      a = b;
    }
    out.sort((x, y) => x.t.compareTo(y.t));
    return out;
  }

  /// Therapy profiles (basal, carb ratio, ISF), newest first.
  Future<List<ProfileDoc>> profiles() async {
    final j = await _get('/api/v1/profile.json', {'count': '200'});
    return parseProfiles(j);
  }

  /// Time of the latest treatment of one of [types] (for sensor / site age).
  /// Nightscout only searches the last 2 days unless a start date is given,
  /// so look back [days] days.
  Future<DateTime?> lastOfTypes(List<String> types, {int days = 30}) async {
    DateTime? best;
    final since = DateTime.now().subtract(Duration(days: days)).toUtc().toIso8601String();
    for (final type in types) {
      final j = await _get('/api/v1/treatments.json', {
        'find[eventType]': type,
        'find[created_at][\$gte]': since,
        'count': '1',
      });
      if (j is List && j.isNotEmpty) {
        final t = _treatment(j.first);
        if (t != null && (best == null || t.t.isAfter(best))) best = t.t;
      }
    }
    return best;
  }

  Future<DeviceInfo> deviceStatus() async {
    // Pump details are not in every upload, so look through more of them.
    final j = await _get('/api/v1/devicestatus.json', {'count': '40'});
    final info = DeviceInfo();
    if (j is! List) return info;
    for (final ds in j) {
      if (ds is! Map) continue;
      final o = ds['openaps'];
      if (o is Map && info.loopTime == null) {
        final iob = o['iob'];
        if (iob is Map) {
          info.iob = _d(iob['iob']);
        } else if (iob is List && iob.isNotEmpty && iob.first is Map) {
          info.iob = _d((iob.first as Map)['iob']);
        }
        final sug = o['suggested'];
        if (sug is Map) {
          info.cob = _d(sug['COB']);
          final p = sug['predBGs'];
          if (p is Map) {
            for (final k in ['COB', 'UAM', 'IOB', 'ZT']) {
              final arr = p[k];
              if (arr is List && arr.isNotEmpty) {
                info.predLines.add(arr.map(_d).whereType<double>().toList());
              }
            }
          }
          info.predStart = _time(sug['deliverAt']) ?? _time(sug['timestamp']);
        }
        final en = o['enacted'];
        if (en is Map) {
          info.basal = _d(en['rate']);
          info.basalMinLeft = _d(en['duration']);
          info.loopTime = _time(en['timestamp']) ?? _time(en['deliverAt']);
        }
        info.loopTime ??= info.predStart ?? _time(ds['created_at']);
      }
      final l = ds['loop'];
      if (l is Map && info.loopTime == null) {
        info.recommendedBolus = _d(l['recommendedBolus']);
        final iob = l['iob'];
        if (iob is Map) info.iob = _d(iob['iob']);
        final cob = l['cob'];
        if (cob is Map) info.cob = _d(cob['cob']);
        final pr = l['predicted'];
        if (pr is Map && pr['values'] is List) {
          info.predLines.add((pr['values'] as List).map(_d).whereType<double>().toList());
          info.predStart = _time(pr['startDate']);
        }
        final en = l['enacted'];
        if (en is Map) {
          info.basal = _d(en['rate']);
          info.basalMinLeft = _d(en['duration']);
        }
        info.loopTime = _time(l['timestamp']) ?? _time(ds['created_at']);
      }
      final ov = ds['override'];
      if (ov is Map && !info.overrideSeen) {
        info.overrideSeen = true;
        info.overrideActive = ov['active'] == true;
        info.overrideName = (ov['name'] ?? '').toString();
        info.overrideMultiplier = _d(ov['multiplier']);
        final start = _time(ov['timestamp']);
        final secs = _d(ov['duration']);
        if (start != null && secs != null && secs > 0 && secs < 7 * 24 * 3600) {
          info.overrideEnd = start.add(Duration(seconds: secs.round()));
          if (info.overrideEnd!.isBefore(DateTime.now())) info.overrideActive = false;
        }
      }
      final p = ds['pump'];
      if (p is Map) {
        info.pumpTime ??= _time(p['clock']) ?? _time(ds['created_at']);
        if (info.reservoir == null && info.reservoirText == null) {
          final over = p['reservoir_display_override'];
          if (over is String && over.isNotEmpty) {
            info.reservoirText = over;
          } else {
            info.reservoir = _d(p['reservoir']);
          }
        }
        final b = p['battery'];
        if (b is Map) {
          info.pumpBattery ??= _d(b['percent'])?.round();
          info.pumpVolts ??= _d(b['voltage']);
        } else if (b is num && info.pumpBattery == null) {
          info.pumpBattery = b.round();
        }
      }
      // Phone (uploader) battery: AAPS sends "uploaderBattery", Loop/xDrip "uploader".
      if (info.phoneBattery == null) {
        final ub = ds['uploaderBattery'];
        final up = ds['uploader'];
        if (ub is num) {
          info.phoneBattery = ub.round();
        } else if (up is Map) {
          info.phoneBattery = _d(up['battery'])?.round();
        }
      }
    }
    return info;
  }

  // ---------- event log (only on your own Monitor Glucose server)

  /// Headers for a change that needs the API secret: the one given, or the
  /// app's own when it is connected with the API secret.
  Map<String, String> _adminHeaders(String? secretOverride) {
    final h = {..._headers, 'Content-Type': 'application/json'};
    if (secretOverride != null && secretOverride.isNotEmpty) {
      h['api-secret'] = sha1.convert(utf8.encode(secretOverride)).toString();
    }
    return h;
  }

  Never _logError(http.Response r) {
    if (r.statusCode == 404) throw NsException('This site has no event log. Only your own Monitor Glucose server keeps one.');
    if (r.statusCode == 401 || r.statusCode == 403) throw NsException('The API secret is needed for this (wrong or missing)');
    throw NsException('The site answered with error ${r.statusCode}');
  }

  Future<List<LogEvent>> logs({List<String> kinds = const [], int count = 500, DateTime? before}) async {
    final r = await http
        .get(_uri('/api/v1/logs', {
          if (kinds.isNotEmpty) 'kind': kinds.join(','),
          'count': '$count',
          if (before != null) 'before': '${before.millisecondsSinceEpoch}',
        }), headers: _headers)
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) _logError(r);
    final j = jsonDecode(r.body);
    final out = <LogEvent>[];
    if (j is List) {
      for (final e in j) {
        if (e is! Map || e['at'] is! num) continue;
        out.add(LogEvent((e['id'] as num?)?.toInt() ?? 0, DateTime.fromMillisecondsSinceEpoch((e['at'] as num).toInt()),
            (e['kind'] ?? '').toString(), (e['msg'] ?? '').toString()));
      }
    }
    return out;
  }

  /// {'on': bool, 'kinds': {kind: bool}, 'keep_days': int}
  Future<Map<String, dynamic>> logSettings() async {
    final r = await http.get(_uri('/api/v1/logs/settings', const {}), headers: _headers).timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) _logError(r);
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  Future<Map<String, dynamic>> saveLogSettings(Map<String, dynamic> settings, {String? secret}) async {
    final r = await http
        .put(_uri('/api/v1/logs/settings', const {}), headers: _adminHeaders(secret), body: jsonEncode(settings))
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) _logError(r);
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  /// Deletes the log lines of [kinds] (all when empty). Returns how many.
  Future<int> clearLogs(List<String> kinds, {String? secret}) async {
    final r = await http
        .delete(_uri('/api/v1/logs', {if (kinds.isNotEmpty) 'kind': kinds.join(',')}), headers: _adminHeaders(secret))
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) _logError(r);
    final j = jsonDecode(r.body);
    return j is Map && j['n'] is num ? (j['n'] as num).toInt() : 0;
  }

  /// Sends a Loop remote command (override, cancel, carbs, bolus) through the
  /// site, which pushes it to the Loop phone with Apple's push service:
  /// Nightscout with its LOOP_APNS_* settings, or your own Monitor Glucose
  /// server with the heartbeat's key. Needs the API secret.
  Future<void> sendLoopCommand(Map<String, dynamic> body, {String? secret}) async {
    final http.Response r;
    try {
      r = await http
          .post(_uri('/api/v2/notifications/loop', const {}), headers: _adminHeaders(secret), body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw NsException('Cannot reach the site: $e');
    }
    if (r.statusCode == 200) return;
    if (r.statusCode == 401 || r.statusCode == 403) throw NsException('The API secret is needed to send commands (wrong or missing)');
    if (r.statusCode == 404) throw NsException('This site cannot send Loop commands (no remote command support)');
    final text = r.body.trim();
    throw NsException(text.isEmpty ? 'The site answered with error ${r.statusCode}' : text);
  }

  Future<void> postTreatment(Map<String, dynamic> t) async {
    final http.Response r;
    try {
      r = await http
          .post(_uri('/api/v1/treatments', const {}),
              headers: {..._headers, 'Content-Type': 'application/json'}, body: jsonEncode([t]))
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      throw NsException('Cannot reach the site: $e');
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw NsException('This token is not allowed to log treatments');
    }
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw NsException('The site answered with error ${r.statusCode}');
    }
  }

  // ---------------------------------------------------------------- food list

  /// Foods from Nightscout's food list (Admin › Food editor, api/v1/food).
  Future<List<Food>> foods() async {
    final j = await _get('/api/v1/food.json', {'count': '5000'});
    if (j is! List) return [];
    return [
      for (final e in j)
        if (e is Map && (e['type'] ?? 'food') == 'food') Food.fromJson(Map<String, dynamic>.from(e))
    ];
  }

  /// Creates or updates a food; returns it with its id.
  Future<Food> saveFood(Food f) async {
    final body = f.toJson();
    final http.Response r;
    try {
      r = await (f.id == null
              ? http.post(_uri('/api/v1/food', const {}), headers: {..._headers, 'Content-Type': 'application/json'}, body: jsonEncode(body))
              : http.put(_uri('/api/v1/food', const {}), headers: {..._headers, 'Content-Type': 'application/json'}, body: jsonEncode(body)))
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      throw NsException('Cannot reach the site: $e');
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw NsException('This token is not allowed to change the food list (it needs the careportal role or the API secret)');
    }
    if (r.statusCode != 200 && r.statusCode != 201) throw NsException('The site answered with error ${r.statusCode}');
    try {
      final j = jsonDecode(r.body);
      final m = j is List && j.isNotEmpty ? j.first : j;
      if (m is Map && m['_id'] != null) f.id = m['_id'].toString();
    } catch (_) {}
    return f;
  }

  Future<void> deleteFood(String id) async {
    final http.Response r;
    try {
      r = await http.delete(_uri('/api/v1/food/$id', const {}), headers: _headers).timeout(const Duration(seconds: 25));
    } catch (e) {
      throw NsException('Cannot reach the site: $e');
    }
    if (r.statusCode == 401 || r.statusCode == 403) throw NsException('This token is not allowed to change the food list');
    if (r.statusCode != 200 && r.statusCode != 204) throw NsException('The site answered with error ${r.statusCode}');
  }

  /// A product from Open Food Facts (free, world-wide, Canada and USA included);
  /// null when the barcode is unknown there.
  static Future<Food?> lookupBarcode(String barcode) async {
    final code = barcode.replaceAll(RegExp(r'[^0-9]'), '');
    if (code.length < 8) throw NsException('That barcode is too short');
    final fields = 'product_name,product_name_en,product_name_fr,generic_name,brands,categories_tags,quantity,'
        'serving_size,serving_quantity,serving_quantity_unit,nutriments,ingredients_text,ingredients_text_en,'
        'ingredients_text_fr,allergens_tags,traces_tags,labels_tags';
    for (final c in {code, if (code.length == 13 && code.startsWith('0')) code.substring(1)}) {
      final http.Response r;
      try {
        r = await http.get(Uri.parse('https://world.openfoodfacts.org/api/v2/product/$c.json?fields=$fields'),
            // Open Food Facts asks apps to name themselves (browsers send their own).
            headers: kIsWeb ? const {} : const {'User-Agent': 'MonitorGlucose/1.0 (https://monitorglucose.ca)'}).timeout(const Duration(seconds: 20));
      } catch (e) {
        throw NsException('Cannot reach Open Food Facts: $e');
      }
      if (r.statusCode == 404) continue;
      if (r.statusCode != 200) throw NsException('Open Food Facts answered with error ${r.statusCode}');
      final f = foodFromOff(jsonDecode(r.body) as Map<String, dynamic>, code);
      if (f != null) return f;
    }
    return null;
  }
}
