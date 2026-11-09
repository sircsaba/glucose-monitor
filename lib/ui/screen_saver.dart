import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../logic/glucose.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Screen saver: a black screen with only the glucose, arrow and minutes since
/// the reading, drifting slowly (no burn-in). Alarms stay quiet while it is on
/// (urgent low can still ring, in the settings). Any touch brings the app back.
class ScreenSaver extends StatefulWidget {
  const ScreenSaver({super.key});
  @override
  State<ScreenSaver> createState() => _ScreenSaverState();
}

class _ScreenSaverState extends State<ScreenSaver> {
  final _rnd = math.Random();
  Alignment _at = Alignment.center;
  Timer? _move;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable().catchError((_) {});
    _move = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _at = Alignment(_rnd.nextDouble() * 1.6 - 0.8, _rnd.nextDouble() * 1.6 - 0.8));
    });
  }

  @override
  void dispose() {
    _move?.cancel();
    if (!app.nightOpen) WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => app.endScreenSaver(),
      child: Material(
        color: Colors.black,
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) {
            final s = app.settings;
            final l = app.latest;
            final mg = l?.mg;
            final bright = s.integer('ssBright').clamp(5, 100) / 100.0;
            final base = mg == null || !s.flag('ssZoneColor') ? const Color(0xFFB0B8C0) : app.colorFor(mg);
            final color = base.withValues(alpha: bright);
            final size = math.min(MediaQuery.sizeOf(context).shortestSide * 0.22, 160.0);
            final age = app.age;
            final stale = app.isStale;
            return AnimatedAlign(
              alignment: _at,
              duration: const Duration(seconds: 25),
              curve: Curves.easeInOut,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    mg == null ? '---' : fmtBg(mg, s.mmol),
                    style: kMono.copyWith(
                      fontSize: size,
                      color: color,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                      decoration: stale ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (mg != null) ArrowIcon(direction: l?.direction ?? '', size: size * 0.5, color: color),
                ]),
                Text(
                  age == null ? 'No data' : fmtAgo(age),
                  style: TextStyle(fontSize: size * 0.2, color: (stale ? kAmber : const Color(0xFFB0B8C0)).withValues(alpha: bright)),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

/// Whether the scheduled screen saver is on at [now]: from the start time,
/// until the end time (when set) or until the screen is touched.
bool screenSaverScheduled({
  required bool on,
  required int from,
  required bool endOn,
  required int to,
  required DateTime now,
  DateTime? dismissed,
}) {
  if (!on) return false;
  final today = DateTime(now.year, now.month, now.day, from ~/ 60, from % 60);
  final start = now.isBefore(today) ? today.subtract(const Duration(days: 1)) : today;
  if (endOn) {
    var mins = (to - from) % 1440;
    if (mins == 0) return false;
    if (!now.isBefore(start.add(Duration(minutes: mins)))) return false;
  }
  return dismissed == null || dismissed.isBefore(start);
}
