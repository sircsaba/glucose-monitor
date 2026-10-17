import 'dart:async';

import 'package:flutter/material.dart';

import '../data/nightscout.dart';
import '../logic/glucose.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Your server's event log: each reading, heartbeat push, loop run, treatment
/// and job problem, with the time between them, to check the system works.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});
  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

const _kinds = {
  'cgm': ('CGM', Color(0xFF3DBE7A)),
  'push': ('Push', Color(0xFFB39DFF)),
  'loop': ('Loop', Color(0xFF5BC0EB)),
  'treatment': ('Treatment', Color(0xFFFF9F43)),
  'remote': ('Remote', Color(0xFFF08BD0)),
  'job': ('Job', Color(0xFFFF4D5A)),
};

/// Gap after which the time since the previous line is shown in amber.
const _lateAfter = {'cgm': Duration(minutes: 6), 'loop': Duration(minutes: 7), 'push': Duration(minutes: 7)};

class _LogsScreenState extends State<LogsScreen> {
  final List<LogEvent> _events = [];
  String? _filter; // null = all
  String? _error;
  bool _loading = false;
  bool _more = true;
  bool _auto = true;
  Timer? _timer;
  String? _secret; // API secret typed for this visit (not saved)

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_auto && mounted) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool older = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final list = await app.client.logs(
        kinds: _filter == null ? const [] : [_filter!],
        count: 300,
        before: older && _events.isNotEmpty ? _events.last.t : null,
      );
      if (!mounted) return;
      setState(() {
        if (!older) _events.clear();
        _events.addAll(list);
        _more = list.length >= 300;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    if (mounted) setState(() => _loading = false);
  }

  /// The API secret: the app's own when connected with it, else asked once.
  Future<String?> _askSecret() async {
    if (app.settings.flag('apiSecret')) return '';
    if (_secret != null) return _secret;
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('API secret'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Changing or clearing the logs needs your server\'s API secret. It is only used now, not saved.',
              style: TextStyle(color: kMuted, fontSize: 13)),
          const SizedBox(height: 10),
          TextField(controller: ctl, obscureText: true, autofocus: true, decoration: const InputDecoration(labelText: 'API secret')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok != true || ctl.text.isEmpty) return null;
    return ctl.text;
  }

  Future<void> _settings() async {
    Map<String, dynamic> s;
    try {
      s = await app.client.logSettings();
    } catch (e) {
      _snack(e.toString());
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(builder: (c, setSheet) {
        final kinds = Map<String, dynamic>.from(s['kinds'] as Map? ?? {});
        Future<void> save(Map<String, dynamic> change) async {
          final secret = await _askSecret();
          if (secret == null) return;
          try {
            final res = await app.client.saveLogSettings(change, secret: secret);
            _secret = secret.isEmpty ? null : secret;
            setSheet(() => s = res);
          } catch (e) {
            _secret = null;
            _snack(e.toString());
          }
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Logging', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Keep a log'),
                subtitle: const Text('Off: nothing more is written (the lines already there stay)'),
                value: s['on'] == true,
                onChanged: (v) => save({'on': v}),
              ),
              for (final k in _kinds.entries)
                SwitchListTile(
                  contentPadding: const EdgeInsets.only(left: 12),
                  dense: true,
                  title: Text(k.value.$1),
                  subtitle: Text(_kindHint(k.key), style: const TextStyle(fontSize: 12)),
                  value: kinds[k.key] == true,
                  onChanged: s['on'] == true ? (v) => save({'kinds': {k.key: v}}) : null,
                ),
              Row(children: [
                const Expanded(child: Text('Keep lines for')),
                IconButton(onPressed: () => save({'keep_days': ((s['keep_days'] as num? ?? 14) - 1).clamp(1, 365)}), icon: const Icon(Icons.remove)),
                Text('${s['keep_days'] ?? 14} days', style: kMono),
                IconButton(onPressed: () => save({'keep_days': ((s['keep_days'] as num? ?? 14) + 1).clamp(1, 365)}), icon: const Icon(Icons.add)),
              ]),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: Text(_filter == null ? 'Clear the whole log' : 'Clear the ${_kinds[_filter]!.$1} lines'),
                onPressed: () async {
                  Navigator.pop(c);
                  await _clear();
                },
              ),
            ]),
          ),
        );
      }),
    );
  }

  String _kindHint(String k) => switch (k) {
        'cgm' => 'Each new reading reaching your server',
        'push' => 'Each heartbeat push sent to Loop',
        'loop' => 'Each loop run uploaded by Loop, with the time since the last',
        'treatment' => 'Boluses, carbs, overrides (not temp basals)',
        'remote' => 'Remote commands sent to Loop (Glucose Monitor Plus, Loop Caregiver)',
        _ => 'LibreLinkUp / Nightscout copy problems and recoveries',
      };

  Future<void> _clear() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear the log?'),
        content: Text(_filter == null ? 'All lines are deleted.' : 'All ${_kinds[_filter]!.$1} lines are deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
        ],
      ),
    );
    if (sure != true) return;
    final secret = await _askSecret();
    if (secret == null) return;
    try {
      final n = await app.client.clearLogs(_filter == null ? const [] : [_filter!], secret: secret);
      _secret = secret.isEmpty ? null : secret;
      _snack('$n lines deleted');
      await _load();
    } catch (e) {
      _secret = null;
      _snack(e.toString());
    }
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  /// Time since the previous line of the same kind (lines are newest first).
  Map<int, Duration> _gaps() {
    final out = <int, Duration>{};
    final last = <String, DateTime>{};
    for (var i = _events.length - 1; i >= 0; i--) {
      final e = _events[i];
      final p = last[e.kind];
      if (p != null) out[i] = e.t.difference(p);
      last[e.kind] = e.t;
    }
    return out;
  }

  Widget _summary() {
    final since = DateTime.now().subtract(const Duration(hours: 6));
    String stats(String kind) {
      final ts = _events.where((e) => e.kind == kind && e.t.isAfter(since)).map((e) => e.t).toList()..sort();
      if (ts.isEmpty) return 'none';
      var longest = Duration.zero;
      for (var i = 1; i < ts.length; i++) {
        final g = ts[i].difference(ts[i - 1]);
        if (g > longest) longest = g;
      }
      final avg = ts.length > 1 ? ts.last.difference(ts.first) ~/ (ts.length - 1) : Duration.zero;
      return '${ts.length}, every ${_fmt(avg)} on average, longest gap ${_fmt(longest)}';
    }

    final fails = _events.where((e) => e.kind == 'loop' && e.t.isAfter(since) && e.msg.contains('FAILED')).length;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Last 6 hours', style: TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        for (final k in ['cgm', 'push', 'loop'])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '${_kinds[k]!.$1}: ', style: TextStyle(color: _kinds[k]!.$2, fontSize: 13, fontWeight: FontWeight.w600)),
              TextSpan(text: stats(k), style: const TextStyle(fontSize: 13)),
            ])),
          ),
        if (fails > 0) Text('$fails loop failure(s)', style: const TextStyle(color: kAmber, fontSize: 13)),
        if (_filter != null) const Text('(only the lines shown are counted)', style: TextStyle(color: kMuted, fontSize: 11)),
      ]),
    );
  }

  static String _fmt(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} s';
    if (d.inMinutes < 60) return '${d.inMinutes} min ${two(d.inSeconds % 60)}';
    return '${d.inHours} h ${two(d.inMinutes % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final gaps = _gaps();
    return Scaffold(
      appBar: AppBar(title: const Text('Logs'), actions: [
        IconButton(
          tooltip: _auto ? 'Auto refresh on (every 30 s)' : 'Auto refresh off',
          icon: Icon(_auto ? Icons.sync : Icons.sync_disabled),
          onPressed: () => setState(() => _auto = !_auto),
        ),
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load),
        IconButton(tooltip: 'Logging settings, clear', icon: const Icon(Icons.tune), onPressed: _settings),
      ]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          itemCount: _events.length + 3,
          itemBuilder: (context, i) {
            if (i == 0) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(label: const Text('All'), selected: _filter == null, onSelected: (_) => setState(() {
                          _filter = null;
                          _load();
                        })),
                  ),
                  for (final k in _kinds.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(label: Text(k.value.$1), selected: _filter == k.key, onSelected: (_) => setState(() {
                            _filter = k.key;
                            _load();
                          })),
                    ),
                ]),
              );
            }
            if (i == 1) {
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (_error != null)
                    Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_error!, style: const TextStyle(color: kAmber))),
                  if (_events.isNotEmpty) _summary(),
                  if (_events.isEmpty && _error == null && !_loading)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No lines yet. They appear as readings, pushes and loops arrive.', style: TextStyle(color: kMuted)),
                    ),
                ]),
              );
            }
            if (i == _events.length + 2) {
              if (!_more || _events.isEmpty) return const SizedBox(height: 8);
              return Center(child: TextButton(onPressed: () => _load(older: true), child: const Text('Show older lines')));
            }
            final idx = i - 2;
            final e = _events[idx];
            final k = _kinds[e.kind] ?? (e.kind, kMuted);
            final gap = gaps[idx];
            final late = gap != null && _lateAfter[e.kind] != null && gap > _lateAfter[e.kind]!;
            final newDay = idx == 0 || _events[idx - 1].t.day != e.t.day;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (newDay)
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 10, 0, 4),
                  child: Text('${e.t.year}-${two(e.t.month)}-${two(e.t.day)}', style: const TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kLine))),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 62,
                    child: Text('${two(e.t.hour)}:${two(e.t.minute)}:${two(e.t.second)}', style: kMono.copyWith(fontSize: 12, color: kMuted)),
                  ),
                  Container(
                    width: 74,
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: k.$2.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(6)),
                    child: Text(k.$1, textAlign: TextAlign.center, style: TextStyle(color: k.$2, fontSize: 11, fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: Text(e.msg,
                        style: TextStyle(fontSize: 13, color: e.msg.contains('FAILED') || (e.kind == 'job' && e.msg.contains('problem')) ? kAmber : kText)),
                  ),
                  if (gap != null && _lateAfter.containsKey(e.kind))
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text('+${_fmt(gap)}', style: kMono.copyWith(fontSize: 11, color: late ? kAmber : kMuted)),
                    ),
                ]),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
