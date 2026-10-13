import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../logic/glucose.dart';
import '../state/app_state.dart';
import 'common.dart';

class AlertScreen extends StatefulWidget {
  const AlertScreen({super.key});
  @override
  State<AlertScreen> createState() => _AlertScreenState();
}

class _AlertScreenState extends State<AlertScreen> {
  Timer? _blink;
  bool _bright = false;
  bool _closing = false;
  late int _custom;

  @override
  void initState() {
    super.initState();
    _custom = app.settings.integer('customSnoozeDef');
    _blink = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _bright = !_bright);
    });
  }

  @override
  void dispose() {
    _blink?.cancel();
    super.dispose();
  }

  String _label(int m) => (m >= 60 && m % 60 == 0) ? '${m ~/ 60} h' : '$m min';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final a = app.active;
        if (a == null) {
          if (!_closing) {
            _closing = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (app.active == null) {
                Navigator.of(context).pop();
              } else {
                _closing = false;
              }
            });
          }
          return const Scaffold(backgroundColor: kBg);
        }
        final s = app.settings;
        final red = isRedAlarm(a.kind);
        final yellow = soundGroup(a.kind) == 1 || soundGroup(a.kind) == 2;
        final base = red ? const Color(0xFFA3121F) : (yellow ? const Color(0xFF7A5A00) : const Color(0xFF2A313C));
        final flash = red ? const Color(0xFFE0353F) : (yellow ? const Color(0xFFB08A10) : const Color(0xFF4A5462));
        final bg = app.flashing && _bright ? flash : base;
        final l = app.latest;
        final mmol = s.mmol;
        final max = app.maxSnoozeFor(a.kind);
        final delta = app.delta5;
        final zoneName = red ? 'RED ZONE' : (yellow ? 'YELLOW ZONE' : 'ALERT');
        final cfg = s.sounds[soundGroup(a.kind)];
        _custom = _custom.clamp(1, math.max(1, max));

        return PopScope(
          canPop: false,
          child: Scaffold(
            backgroundColor: bg,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(14)),
                    child: Text(
                      '${a.test ? 'TEST · ' : ''}$zoneName · ${app.range.name.toUpperCase()}',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.4),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(alarmTitle(a.kind), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  if (l != null)
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(fmtBg(l.mg, mmol), style: kMono.copyWith(fontSize: 96, height: 1, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 6),
                      ArrowIcon(direction: l.direction, size: 48, color: Colors.white),
                    ]),
                  const SizedBox(height: 8),
                  if (l != null)
                    Text(
                      '${fmtAgo(DateTime.now().difference(l.t))}'
                      '${delta == null ? '' : ' · ${fmtDelta(delta, mmol)} ${unitLabel(mmol)} (5 min avg)'}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    app.flashing ? 'Sound starts in a moment…' : '"${_soundName(cfg.sound)}" playing',
                    style: const TextStyle(fontSize: 14, color: Colors.white70),
                  ),
                  const Spacer(),
                  Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                    for (final m in s.snoozePresets)
                      SizedBox(
                        width: 80,
                        height: 52,
                        child: OutlinedButton(
                          onPressed: m <= max ? () => app.snooze(m) : null,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            disabledForegroundColor: Colors.white54,
                            side: BorderSide(color: m <= max ? Colors.white70 : Colors.white30),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: EdgeInsets.zero,
                          ),
                          child: Text(
                            _label(m),
                            style: TextStyle(fontSize: 15, decoration: m <= max ? null : TextDecoration.lineThrough),
                          ),
                        ),
                      ),
                  ]),
                  if (s.flag('allowCustomSnooze')) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(14)),
                      child: Row(children: [
                        _round('−', () => setState(() => _custom = math.max(1, _custom - 1))),
                        Expanded(child: Text('$_custom min', textAlign: TextAlign.center, style: kMono.copyWith(fontSize: 20))),
                        _round('+', () => setState(() => _custom = math.min(max, _custom + 1))),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: base,
                            minimumSize: const Size(90, 48),
                          ),
                          onPressed: () => app.snooze(_custom),
                          child: const Text('Snooze', style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (red) Text('Red zone: longest snooze is $max min', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: base),
                      onPressed: () => app.snooze(s.integer('treatingSnoozeMin')),
                      child: const Text("I'm treating it", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  String _soundName(int i) {
    const names = ['Morning mist', 'Lullaby strings', 'Ocean calm', 'Wind chimes', 'Soft guitar', 'Music box', 'Gentle bell', 'Classic alarm', 'Beeps', 'Siren'];
    return names[i.clamp(0, names.length - 1)];
  }

  Widget _round(String t, VoidCallback f) => SizedBox(
        width: 48,
        height: 48,
        child: OutlinedButton(
          onPressed: f,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white60),
          ),
          child: Text(t, style: const TextStyle(fontSize: 22)),
        ),
      );
}
