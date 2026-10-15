import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/nightscout.dart';
import '../state/settings.dart';

enum Zone { redLow, yellowLow, green, yellowHigh, redHigh }

const Color kRed = Color(0xFFFF4D5A);
const Color kYellow = Color(0xFFF2C94C);
const Color kGreen = Color(0xFF3DBE7A);

Color zoneColor(Zone z) {
  switch (z) {
    case Zone.redLow:
    case Zone.redHigh:
      return kRed;
    case Zone.yellowLow:
    case Zone.yellowHigh:
      return kYellow;
    case Zone.green:
      return kGreen;
  }
}

/// The colour of a zone in a given time range (each range can have its own colours).
Color zoneColorIn(Zone z, ZoneRange r) {
  switch (z) {
    case Zone.redLow:
    case Zone.redHigh:
      return Color(r.cRed);
    case Zone.yellowLow:
    case Zone.yellowHigh:
      return Color(r.cYel);
    case Zone.green:
      return Color(r.cGreen);
  }
}

Zone zoneOf(double mg, ZoneRange r) {
  if (mg < r.redLo) return Zone.redLow;
  if (mg < r.yelLo) return Zone.yellowLow;
  if (mg <= r.yelHi) return Zone.green;
  if (mg <= r.redHi) return Zone.yellowHigh;
  return Zone.redHigh;
}

/// The range that applies at [t]: the first one in the list that covers it.
ZoneRange activeRange(List<ZoneRange> ranges, DateTime t) {
  for (final r in ranges) {
    if (r.covers(t)) return r;
  }
  return ranges.first;
}

String fmtBg(double mg, bool mmol) => mmol ? (mg / mgPerMmol).toStringAsFixed(1) : mg.round().toString();

String fmtDelta(double mg, bool mmol) {
  final v = mmol ? mg / mgPerMmol : mg;
  final s = mmol ? v.abs().toStringAsFixed(1) : v.abs().round().toString();
  final zero = mmol ? s == '0.0' : s == '0';
  if (zero) return mmol ? '+0.0' : '+0';
  return (v >= 0 ? '+' : '−') + s;
}

String unitLabel(bool mmol) => mmol ? 'mmol/L' : 'mg/dL';

String two(int n) => n < 10 ? '0$n' : '$n';

String fmtClock(DateTime t, bool h24) {
  if (h24) return '${two(t.hour)}:${two(t.minute)}';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';
}

String fmtMinutesOfDay(int m, bool h24) {
  final mm = ((m % 1440) + 1440) % 1440;
  return fmtClock(DateTime(2000, 1, 1, mm ~/ 60, mm % 60), h24);
}

String fmtAge(Duration d) {
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 48) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inDays}d ${d.inHours % 24}h';
}

String fmtAgo(Duration d) {
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes == 1) return '1 min ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  return '${fmtAge(d)} ago';
}

/// Average change over the last 5 minutes, in mg/dL per 5 minutes.
/// Works for 5-minute and 1-minute sensors.
double? avgDelta5(List<Entry> e) {
  if (e.length < 2) return null;
  final last = e.last;
  final window = e.where((x) => last.t.difference(x.t).inSeconds <= 330 && x != last).toList();
  Entry? first;
  if (window.isNotEmpty) {
    first = window.first;
  } else {
    final prev = e[e.length - 2];
    if (last.t.difference(prev.t).inMinutes > 15) return null;
    first = prev;
  }
  final mins = last.t.difference(first.t).inSeconds / 60.0;
  if (mins <= 0.1) return null;
  return (last.mg - first.mg) / mins * 5.0;
}

/// Rotation (radians) for a Nightscout direction, null if unknown.
double? arrowAngle(String dir) {
  switch (dir) {
    case 'DoubleUp':
    case 'SingleUp':
      return -math.pi / 2;
    case 'FortyFiveUp':
      return -math.pi / 4;
    case 'Flat':
      return 0;
    case 'FortyFiveDown':
      return math.pi / 4;
    case 'SingleDown':
    case 'DoubleDown':
      return math.pi / 2;
  }
  return null;
}

bool isDoubleArrow(String dir) => dir == 'DoubleUp' || dir == 'DoubleDown';

/// Text arrow used where an icon can't go (one line of text).
String arrowText(String dir) {
  switch (dir) {
    case 'DoubleUp':
      return '⇈';
    case 'SingleUp':
      return '↑';
    case 'FortyFiveUp':
      return '↗';
    case 'Flat':
      return '→';
    case 'FortyFiveDown':
      return '↘';
    case 'SingleDown':
      return '↓';
    case 'DoubleDown':
      return '⇊';
  }
  return '';
}

class ArrowIcon extends StatelessWidget {
  final String direction;
  final double size;
  final Color color;
  final double length; // 1 = the standard arrow icon; more = a longer drawn arrow
  const ArrowIcon({super.key, required this.direction, required this.size, required this.color, this.length = 1.0});

  @override
  Widget build(BuildContext context) {
    final a = arrowAngle(direction);
    if (a == null) return SizedBox(width: size * 0.2);
    if (length > 1.01) {
      final side = size * length;
      return CustomPaint(size: Size(side, side), painter: _ArrowPainter(a, isDoubleArrow(direction), color, size, length));
    }
    final one = Transform.rotate(angle: a, child: Icon(Icons.arrow_forward_rounded, size: size, color: color));
    if (!isDoubleArrow(direction)) return one;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      one,
      Transform.translate(offset: Offset(-size * 0.45, 0), child: one),
    ]);
  }
}

/// A long arrow: a shaft and a pointed head, turned to the trend direction.
class _ArrowPainter extends CustomPainter {
  final double angle;
  final bool twin;
  final Color color;
  final double size;
  final double length;
  _ArrowPainter(this.angle, this.twin, this.color, this.size, this.length);

  @override
  void paint(Canvas canvas, Size box) {
    final half = size * length * 0.42;
    final head = size * 0.34;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.13
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.translate(box.width / 2, box.height / 2);
    canvas.rotate(angle);
    for (final off in twin ? [-size * 0.2, size * 0.2] : [0.0]) {
      canvas.drawLine(Offset(-half, off), Offset(half - stroke.strokeWidth * 0.4, off), stroke);
      final p = Path()
        ..moveTo(half - head, off - head * 0.85)
        ..lineTo(half, off)
        ..lineTo(half - head, off + head * 0.85);
      canvas.drawPath(p, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) =>
      old.angle != angle || old.color != color || old.size != size || old.length != length || old.twin != twin;
}
