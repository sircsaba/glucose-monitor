import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

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
  final bool isSmb;
  final String notes;
  Treatment({
    required this.t,
    required this.type,
    this.insulin,
    this.carbs,
    this.absolute,
    this.duration,
    this.isSmb = false,
    this.notes = '',
  });
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
  int? pumpBattery;

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
    final http.Response r;
    try {
      r = await http.get(_uri(path, q), headers: _headers).timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw NsException('The site did not answer in time');
    } catch (e) {
      throw NsException('Cannot reach the site: $e');
    }
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
      isSmb: e['isSMB'] == true || (e['type'] ?? '').toString() == 'SMB',
      notes: (e['notes'] ?? '').toString(),
    );
  }

  Future<List<Treatment>> treatmentsSince(DateTime since) async {
    final j = await _get('/api/v1/treatments.json', {
      'find[created_at][\$gte]': since.toUtc().toIso8601String(),
      'count': '1000',
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

  /// Time of the latest treatment of one of [types] (for sensor / site age).
  Future<DateTime?> lastOfTypes(List<String> types) async {
    DateTime? best;
    for (final type in types) {
      final j = await _get('/api/v1/treatments.json', {'find[eventType]': type, 'count': '1'});
      if (j is List && j.isNotEmpty) {
        final t = _treatment(j.first);
        if (t != null && (best == null || t.t.isAfter(best))) best = t.t;
      }
    }
    return best;
  }

  Future<DeviceInfo> deviceStatus() async {
    final j = await _get('/api/v1/devicestatus.json', {'count': '10'});
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
      final p = ds['pump'];
      if (p is Map) {
        info.reservoir ??= _d(p['reservoir']);
        final b = p['battery'];
        if (b is Map && info.pumpBattery == null) info.pumpBattery = _d(b['percent'])?.round();
      }
      final up = ds['uploader'];
      if (up is Map && info.pumpBattery == null && ds['pump'] == null) {
        // Some uploaders only send the phone battery; ignore it for the pump.
      }
    }
    return info;
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
}
