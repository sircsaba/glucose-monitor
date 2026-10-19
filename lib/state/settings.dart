import 'dart:convert';

/// Glucose values are always stored in mg/dL inside the app.
const double mgPerMmol = 18.0182;

/// One time range with its own red / yellow / green limits.
class ZoneRange {
  String name;
  int from; // minutes after midnight
  int to; // minutes after midnight (may be smaller than [from]: crosses midnight)
  List<bool> days; // Monday .. Sunday
  double redLo;
  double yelLo;
  double yelHi;
  double redHi;
  // Colours used for this range's zones (ARGB).
  int cRed;
  int cYel;
  int cGreen;

  ZoneRange({
    required this.name,
    required this.from,
    required this.to,
    required this.days,
    required this.redLo,
    required this.yelLo,
    required this.yelHi,
    required this.redHi,
    this.cRed = 0xFFFF4D5A,
    this.cYel = 0xFFF2C94C,
    this.cGreen = 0xFF3DBE7A,
  });

  /// True when [t] falls inside this range.
  bool covers(DateTime t) {
    final wd = t.weekday - 1;
    final m = t.hour * 60 + t.minute;
    if (from == to) return days[wd];
    if (from < to) return days[wd] && m >= from && m < to;
    if (m >= from) return days[wd];
    if (m < to) return days[(wd + 6) % 7];
    return false;
  }

  ZoneRange copy() => ZoneRange.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'name': name,
        'from': from,
        'to': to,
        'days': days,
        'redLo': redLo,
        'yelLo': yelLo,
        'yelHi': yelHi,
        'redHi': redHi,
        'cRed': cRed,
        'cYel': cYel,
        'cGreen': cGreen,
      };

  factory ZoneRange.fromJson(Map<String, dynamic> j) => ZoneRange(
        name: (j['name'] ?? 'Range').toString(),
        from: (j['from'] as num? ?? 0).toInt(),
        to: (j['to'] as num? ?? 0).toInt(),
        days: ((j['days'] as List?) ?? List.filled(7, true)).map((e) => e == true).toList(),
        redLo: (j['redLo'] as num? ?? 63).toDouble(),
        yelLo: (j['yelLo'] as num? ?? 81).toDouble(),
        yelHi: (j['yelHi'] as num? ?? 180).toDouble(),
        redHi: (j['redHi'] as num? ?? 234).toDouble(),
        cRed: (j['cRed'] as num? ?? 0xFFFF4D5A).toInt(),
        cYel: (j['cYel'] as num? ?? 0xFFF2C94C).toInt(),
        cGreen: (j['cGreen'] as num? ?? 0xFF3DBE7A).toInt(),
      );
}

/// Sound and volume behaviour for one kind of alarm.
class SoundCfg {
  bool enabled;
  int sound; // index into kSounds
  int volMode; // 0 = stays the same, 1 = gets louder, 2 = gets softer
  int v1; // start volume %
  int v2; // end volume %
  int secs; // seconds to go from v1 to v2
  bool vibrate;

  SoundCfg({
    this.enabled = true,
    this.sound = 0,
    this.volMode = 1,
    this.v1 = 30,
    this.v2 = 100,
    this.secs = 60,
    this.vibrate = true,
  });

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'sound': sound,
        'volMode': volMode,
        'v1': v1,
        'v2': v2,
        'secs': secs,
        'vibrate': vibrate,
      };

  factory SoundCfg.fromJson(Map<String, dynamic> j) => SoundCfg(
        enabled: j['enabled'] != false,
        sound: (j['sound'] as num? ?? 0).toInt(),
        volMode: (j['volMode'] as num? ?? 0).toInt(),
        v1: (j['v1'] as num? ?? 60).toInt(),
        v2: (j['v2'] as num? ?? 60).toInt(),
        secs: (j['secs'] as num? ?? 60).toInt(),
        vibrate: j['vibrate'] != false,
      );
}

/// One element of the night view or of the day view.
class LineCfg {
  String id; // night: clock, bg, ago, delta, since, iob, graph. Day: see kDayNames.
  bool show;
  double size;
  bool zoneColor;
  int color; // ARGB
  String align; // left, center, right
  double space;
  bool bold;
  // Day view only.
  int flex; // share of the line's width
  bool join; // on the same line as the element before
  bool box; // drawn on a card
  bool stack; // label above the value (instead of beside it)
  bool under; // under the element before, in the same spot on its line

  LineCfg({
    required this.id,
    this.show = true,
    this.size = 20,
    this.zoneColor = true,
    this.color = 0xFFE6EDF3,
    this.align = 'center',
    this.space = 8,
    this.bold = false,
    this.flex = 1,
    this.join = false,
    this.box = false,
    this.stack = false,
    this.under = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'show': show,
        'size': size,
        'zoneColor': zoneColor,
        'color': color,
        'align': align,
        'space': space,
        'bold': bold,
        'flex': flex,
        'join': join,
        'box': box,
        'stack': stack,
        'under': under,
      };

  factory LineCfg.fromJson(Map<String, dynamic> j) => LineCfg(
        id: (j['id'] ?? 'bg').toString(),
        show: j['show'] != false,
        size: (j['size'] as num? ?? 20).toDouble(),
        zoneColor: j['zoneColor'] != false,
        color: (j['color'] as num? ?? 0xFFE6EDF3).toInt(),
        align: (j['align'] ?? 'center').toString(),
        space: (j['space'] as num? ?? 8).toDouble(),
        bold: j['bold'] == true,
        flex: (j['flex'] as num? ?? 1).toInt().clamp(1, 12),
        join: j['join'] == true,
        box: j['box'] == true,
        stack: j['stack'] == true,
        under: j['under'] == true,
      );
}

/// Names shown for each night-view line.
const Map<String, String> kLineNames = {
  'clock': 'Clock',
  'bg': 'Glucose value',
  'ago': 'Minutes since reading',
  'delta': 'Avg change (5 min)',
  'since': 'Last bolus & carbs',
  'iob': 'IOB / COB',
  'graph': 'Small graph',
};

/// Names shown for each day-view element.
const Map<String, String> kDayNames = {
  'name': 'Patient name',
  'ago': 'Minutes since reading',
  'loop': 'Loop status',
  'clock': 'Clock',
  'bg': 'Glucose value',
  'delta': 'Avg change (separate)',
  'iob': 'IOB',
  'cob': 'COB',
  'basal': 'Basal',
  'reservoir': 'Reservoir',
  'battery': 'Pump battery',
  'bolus': 'Last bolus',
  'carbs': 'Last carbs',
  'graph': 'Graph',
  'sensor': 'Sensor age',
  'cannula': 'Cannula age',
  'phone': 'Looping phone battery',
  'ttir': 'Time in range today (TIR / TTIR)',
  'today': 'Today so far (carbs, insulin, ICR, ISF)',
  'profile': 'Profile in use',
};

/// Alarm sounds bundled with the app (assets/sounds/<file>.wav).
class SoundDef {
  final String file;
  final String name;
  final String sub;
  final bool soft;
  const SoundDef(this.file, this.name, this.sub, this.soft);
}

const List<SoundDef> kSounds = [
  SoundDef('morning_mist', 'Morning mist', 'Soft piano', true),
  SoundDef('lullaby_strings', 'Lullaby strings', 'Slow strings', true),
  SoundDef('ocean_calm', 'Ocean calm', 'Waves and pads', true),
  SoundDef('wind_chimes', 'Wind chimes', 'Light chimes', true),
  SoundDef('soft_guitar', 'Soft guitar', 'Plucked strings', true),
  SoundDef('music_box', 'Music box', 'Gentle melody', true),
  SoundDef('gentle_bell', 'Gentle bell', 'Single bell, repeats', false),
  SoundDef('classic_alarm', 'Classic alarm', 'Alarm clock', false),
  SoundDef('beeps', 'Beeps', 'Short beeps', false),
  SoundDef('siren', 'Siren', 'Very loud', false),
];

/// Sound groups: which SoundCfg each alarm uses.
const List<String> kSoundGroups = ['Red low', 'Yellow low', 'Yellow high', 'Red high', 'Other alarms'];

class Settings {
  /// Every simple setting with its default value. Glucose values are mg/dL.
  static const Map<String, dynamic> defaults = {
    // Data
    'nsUrl': '',
    'nsToken': '',
    'apiSecret': false,
    'mmol': true,
    'refreshSec': 60,
    'enteredBy': '',
    'allowTreatments': true,
    'time24': true,
    // Graph
    'graphHours': 3,
    'graphButtons': [1, 2, 3, 6, 12], // the 5 buttons above the graph, in hours
    'graphTop': 0, // 0 = auto, else the top of the graph in mg/dL
    'dotSize': 0, // 0 small, 1 medium, 2 large
    // Monitor Glucose Plus: Loop remote control limits and name.
    'remoteMaxBolus': 2.0,
    'remoteMaxCarbs': 50.0,
    'remoteName': '',
    'patientName': '',
    'tirPeriod': 0, // main-screen TIR card: 0 today since midnight, 1 last 24 h
    'screenMode': 0, // 0 auto, 1 computer layout, 2 phone layout
    'dotBright': 100, // % brightness of the glucose dots
    // Time in tight range (TTIR): 70–140 mg/dL (3.9–7.8 mmol/L). The part of the
    // range above it is tinted on graphs and shown on reports.
    'profileShow': true, // profile name and changes on the graph
    'ttirOn': true,
    'ttirHi': 140.0,
    'ttirColor': 0xFFFFF3A0,
    'uiScale': 0, // 0 = auto (bigger on tablets), else percent

    'showPrediction': true,
    'showBasal': true,
    'showTreatments': true,
    'treatSize': 100, // treatment markers on the graph, percent
    'treatPlace': 0, // 0 = top of the graph, 1 = on the glucose line
    'gridLines': true, // dotted grid on the graph
    'basalLabels': true, // rate written on top of the temp basal bars
    'basalTextSize': 10.0,
    'basalTextBold': false,
    'basalTextColor': 0xFF9CC3E0,
    'basalBarColor': 0xFF2B4A63,
    'presetShow': true, // Loop overrides / Trio temp targets on the graph
    'presetColor': 0xFFB39DFF,
    'presetTextSize': 11.0,
    'presetBold': false,
    'gridMinutes': [15, 15, 15, 30, 60], // minutes between time lines, for each graph button
    'tipBg': 2, // mouse over a reading: 0 nothing, 1 value, 2 value and time, 3 time
    'tipTreat': 2, // mouse over a treatment: same choices
    'navCompact': 0, // bottom bar: 0 thin on a computer, 1 always thin, 2 always normal
    'landSplit': true, // phone on its side: values left, graph right
    'splitLeft': 40, // percent of the width for the values
    'graphFit': 0, // 0 fit the screen on a computer, 1 always fit the screen, 2 fixed height
    'arrowLen': 0, // day view trend arrow length, percent (0 = auto: 150 on a computer, 100 on a phone)
    'bgSide': 0, // arrow and change: 0 auto (side by side on a computer), 1 stacked, 2 side by side
    'dayArrow': true,
    'dayBgDelta': true, // change and units next to the glucose value
    'dayCustom': false, // false = default layout for the screen (original on phones, compact on wide screens)
    'tirLo': 70.0,
    'tirHi': 180.0,
    // Other alarms
    'noDataOn': true,
    'noDataMin': 15,
    'predLowOn': true,
    'predLowMin': 20,
    'loopOn': true,
    'loopMin': 30,
    // Flashing fault message on the top line when readings or loops are this late
    'faultMin': 10,
    'reservoirOn': true,
    'reservoirU': 20,
    'pumpBatOn': true,
    'pumpBatPct': 20,
    // One-time target alert (Target tab)
    'tgtMg': 83.0, // 4.6 mmol/L
    'tgtSoundOn': true,
    'tgtSound': 6, // Gentle bell
    'tgtVolume': 80,
    'tgtVibrate': true,
    'tgtFlash': true,
    'tgtColor': 0xFF3DBE7A,
    'tgtTimerMin': 30, // 0 = no countdown
    'tgtTimerAction': 0, // 0 alert me to take action, 1 just cancel
    // Gentle wake-up
    'gentleOn': true,
    'flashSec': 15,
    'urgentSkipsGentle': true,
    // Snooze
    'smartSnooze': true,
    'wakeIfUrgent': true,
    'maxSnoozeMin': 120,
    'maxRedSnooze': 15,
    'allowCustomSnooze': true,
    'customSnoozeDef': 25,
    'treatingSnoozeMin': 15,
    // Quiet hours
    'quietOn': false,
    'quietFrom': 1380,
    'quietTo': 390,
    'quietMode': 0, // 0 mute yellow, 1 half volume, 2 vibrate only
    // Night view
    'nightBrightness': 40,
    'nightKeepAwake': true,
    'nightStaleMin': 10,
    'nightBlockPos': 1, // 0 top, 1 middle, 2 bottom
    'nightArrow': true,
    'nightAutoOn': false,
    'nightFrom': 1260,
    'nightTo': 420,
    'nightOrientation': 0, // 0 auto, 1 portrait, 2 landscape
    'nightBurnIn': true,
    // Before-sleep checklist
    'ckOn': true,
    'ckAt': 1290,
    'ckInsulinU': 20,
    'ckPumpBat': 25,
    'sensorDays': 10,
    'siteHours': 72,
  };

  final Map<String, dynamic> v;
  List<ZoneRange> ranges;
  List<SoundCfg> sounds;
  List<LineCfg> lines;
  List<LineCfg> day;
  List<int> snoozePresets;

  Settings({
    required this.v,
    required this.ranges,
    required this.sounds,
    required this.lines,
    required this.day,
    required this.snoozePresets,
  });

  factory Settings.initial() => Settings(
        v: {},
        ranges: defaultRanges(),
        sounds: defaultSounds(),
        lines: defaultLines(),
        day: defaultDay(),
        snoozePresets: [10, 20, 30, 60],
      );

  static List<ZoneRange> defaultRanges() {
    List<bool> all() => List.filled(7, true);
    return [
      ZoneRange(name: 'Night', from: 1260, to: 420, days: all(), redLo: 72, yelLo: 90, yelHi: 198, redHi: 252),
      ZoneRange(name: 'Day', from: 420, to: 1260, days: all(), redLo: 63, yelLo: 81, yelHi: 180, redHi: 234),
    ];
  }

  static List<SoundCfg> defaultSounds() => [
        SoundCfg(sound: 0, volMode: 1, v1: 30, v2: 100, secs: 60),
        SoundCfg(sound: 1, volMode: 1, v1: 10, v2: 70, secs: 90),
        SoundCfg(sound: 3, volMode: 0, v1: 50, v2: 50, secs: 60),
        SoundCfg(sound: 6, volMode: 1, v1: 30, v2: 100, secs: 60),
        SoundCfg(sound: 8, volMode: 0, v1: 60, v2: 60, secs: 60),
      ];

  static List<LineCfg> defaultLines() => [
        LineCfg(id: 'clock', size: 30, zoneColor: false, color: 0xFF9AA4B2, space: 0),
        LineCfg(id: 'bg', size: 130, bold: true, space: 10),
        LineCfg(id: 'ago', size: 28, space: 12),
        LineCfg(id: 'delta', size: 22, space: 8),
        LineCfg(id: 'since', size: 15, zoneColor: false, color: 0xFF9AA4B2, space: 18),
        LineCfg(id: 'iob', size: 15, zoneColor: false, color: 0xFF9AA4B2, space: 6, show: false),
        LineCfg(id: 'graph', size: 70, space: 20),
      ];

  /// Day view presets. Original: the first phone layout (labels above values).
  /// Compact: IOB, COB, basal, reservoir and pump battery on one line with the
  /// label beside the value, the clock left of a bigger glucose value.
  /// [big] makes everything larger for a computer screen.
  static List<LineCfg> defaultDay({bool compact = false, bool big = false}) {
    const white = 0xFFE6EDF3;
    const grey = 0xFF9AA4B2;
    const soft = 0xFFC4CCD6;
    const blue = 0xFF5BC0EB;
    if (!compact) {
      return [
        LineCfg(id: 'name', size: 16, zoneColor: false, color: white, align: 'center', space: 0, bold: true),
        LineCfg(id: 'ago', size: 13, zoneColor: false, color: grey, align: 'left', space: 0),
        LineCfg(id: 'loop', size: 13, zoneColor: false, color: grey, align: 'right', space: 0, join: true),
        LineCfg(id: 'clock', size: 20, zoneColor: false, color: blue, align: 'left', space: 8, flex: 2, show: false),
        LineCfg(id: 'bg', size: 84, align: 'center', space: 8, bold: true, flex: 8, join: true),
        LineCfg(id: 'delta', size: 18, zoneColor: false, color: white, align: 'right', space: 0, flex: 2, join: true, show: false),
        LineCfg(id: 'iob', size: 18, zoneColor: false, color: white, align: 'left', space: 8, box: true, stack: true, bold: true),
        LineCfg(id: 'cob', size: 18, zoneColor: false, color: white, align: 'left', space: 8, box: true, stack: true, bold: true, join: true),
        LineCfg(id: 'basal', size: 18, zoneColor: false, color: white, align: 'left', space: 8, box: true, stack: true, bold: true, join: true),
        LineCfg(id: 'bolus', size: 13, zoneColor: false, color: soft, align: 'left', space: 10),
        LineCfg(id: 'carbs', size: 13, zoneColor: false, color: soft, align: 'right', space: 10, join: true),
        LineCfg(id: 'graph', size: 260, space: 12),
        LineCfg(id: 'reservoir', size: 13, zoneColor: false, color: white, space: 14, stack: true),
        LineCfg(id: 'battery', size: 13, zoneColor: false, color: white, space: 14, stack: true, join: true),
        LineCfg(id: 'sensor', size: 13, zoneColor: false, color: white, space: 14, stack: true, join: true),
        LineCfg(id: 'cannula', size: 13, zoneColor: false, color: white, space: 14, stack: true, join: true),
        LineCfg(id: 'phone', size: 12, zoneColor: false, color: grey, space: 8),
        LineCfg(id: 'ttir', size: 13, zoneColor: false, color: white, space: 8, box: true),
        LineCfg(id: 'profile', size: 13, zoneColor: false, color: white, space: 8, box: true, join: true),
        LineCfg(id: 'today', size: 13, zoneColor: false, color: white, space: 8, box: true, align: 'left'),
      ];
    }
    if (big) {
      // Computer screen: the sizes of the earlier wide layout, in one column.
      return [
        LineCfg(id: 'name', size: 22, zoneColor: false, color: white, align: 'center', space: 0, bold: true),
        LineCfg(id: 'ago', size: 18, zoneColor: false, color: grey, align: 'left', space: 0),
        LineCfg(id: 'loop', size: 18, zoneColor: false, color: grey, align: 'right', space: 0, join: true),
        LineCfg(id: 'clock', size: 44, zoneColor: false, color: blue, align: 'left', space: 0, flex: 3),
        LineCfg(id: 'bg', size: 170, align: 'center', space: 0, bold: true, flex: 7, join: true),
        LineCfg(id: 'delta', size: 24, zoneColor: false, color: white, align: 'right', space: 0, flex: 2, join: true, show: false),
        LineCfg(id: 'bolus', size: 20, zoneColor: false, color: soft, align: 'left', space: 0, flex: 3, join: true),
        LineCfg(id: 'carbs', size: 20, zoneColor: false, color: soft, align: 'left', space: 8, flex: 3, under: true),
        LineCfg(id: 'iob', size: 22, zoneColor: false, color: white, space: 8, flex: 2, box: true),
        LineCfg(id: 'cob', size: 22, zoneColor: false, color: white, space: 16, flex: 2, box: true, join: true),
        LineCfg(id: 'basal', size: 22, zoneColor: false, color: white, space: 16, flex: 3, box: true, join: true),
        LineCfg(id: 'reservoir', size: 22, zoneColor: false, color: white, space: 16, flex: 2, box: true, join: true),
        LineCfg(id: 'battery', size: 22, zoneColor: false, color: white, space: 16, flex: 2, box: true, join: true),
        LineCfg(id: 'sensor', size: 22, zoneColor: false, color: white, space: 16, flex: 3, box: true, join: true),
        LineCfg(id: 'cannula', size: 22, zoneColor: false, color: white, space: 16, flex: 3, box: true, join: true),
        LineCfg(id: 'phone', size: 22, zoneColor: false, color: white, space: 16, flex: 2, box: true, join: true),
        LineCfg(id: 'ttir', size: 22, zoneColor: false, color: white, space: 16, flex: 4, box: true, join: true),
        LineCfg(id: 'graph', size: 420, space: 14),
        LineCfg(id: 'profile', size: 16, zoneColor: false, color: white, space: 10, flex: 1, box: true),
        LineCfg(id: 'today', size: 16, zoneColor: false, color: white, space: 10, flex: 5, box: true, join: true, align: 'left'),
      ];
    }
    const k = 1.0;
    double z(double v) => (v * k).roundToDouble();
    return [
      LineCfg(id: 'name', size: z(16), zoneColor: false, color: white, align: 'center', space: 0, bold: true),
      LineCfg(id: 'ago', size: z(13), zoneColor: false, color: grey, align: 'left', space: 0),
      LineCfg(id: 'loop', size: z(13), zoneColor: false, color: grey, align: 'right', space: 0, join: true),
      LineCfg(id: 'clock', size: z(26), zoneColor: false, color: blue, align: 'left', space: z(4), flex: 2),
      LineCfg(id: 'bg', size: z(110), align: 'center', space: z(4), bold: true, flex: 8, join: true),
      LineCfg(id: 'delta', size: z(18), zoneColor: false, color: white, align: 'right', space: 0, flex: 2, join: true, show: false),
      LineCfg(id: 'iob', size: z(14), zoneColor: false, color: white, space: z(8), flex: 2, box: true, bold: true),
      LineCfg(id: 'cob', size: z(14), zoneColor: false, color: white, space: z(8), flex: 2, box: true, bold: true, join: true),
      LineCfg(id: 'basal', size: z(14), zoneColor: false, color: white, space: z(8), flex: 3, box: true, bold: true, join: true),
      LineCfg(id: 'reservoir', size: z(14), zoneColor: false, color: white, space: z(8), flex: 2, box: true, bold: true, join: true),
      LineCfg(id: 'battery', size: z(14), zoneColor: false, color: white, space: z(8), flex: 2, box: true, bold: true, join: true),
      LineCfg(id: 'bolus', size: z(13), zoneColor: false, color: soft, align: 'left', space: z(8)),
      LineCfg(id: 'carbs', size: z(13), zoneColor: false, color: soft, align: 'right', space: z(8), join: true),
      LineCfg(id: 'graph', size: big ? 380 : 260, space: z(8)),
      LineCfg(id: 'sensor', size: z(13), zoneColor: false, color: soft, space: z(8)),
      LineCfg(id: 'cannula', size: z(13), zoneColor: false, color: soft, space: z(8), join: true),
      LineCfg(id: 'phone', size: z(13), zoneColor: false, color: soft, space: z(8), join: true),
      LineCfg(id: 'ttir', size: z(13), zoneColor: false, color: white, space: z(8), box: true),
      LineCfg(id: 'profile', size: z(13), zoneColor: false, color: white, space: z(8), box: true, join: true),
      LineCfg(id: 'today', size: z(13), zoneColor: false, color: white, space: z(8), box: true, align: 'left'),
    ];
  }

  /// The day layout in use: the saved one once edited or chosen, else the
  /// default for the screen (original on a phone, compact on a wide screen).
  List<LineCfg> dayFor(bool wide) => flag('dayCustom') ? day : defaultDay(compact: wide, big: wide);

  dynamic raw(String k) => v.containsKey(k) ? v[k] : defaults[k];
  String str(String k) => (raw(k) ?? '').toString();
  bool flag(String k) => raw(k) == true;
  int integer(String k) => (raw(k) as num? ?? 0).toInt();
  double number(String k) => (raw(k) as num? ?? 0).toDouble();
  void set(String k, dynamic value) => v[k] = value;

  bool get mmol => flag('mmol');

  Map<String, dynamic> toJson() => {
        'v': v,
        'ranges': ranges.map((e) => e.toJson()).toList(),
        'sounds': sounds.map((e) => e.toJson()).toList(),
        'lines': lines.map((e) => e.toJson()).toList(),
        'day': day.map((e) => e.toJson()).toList(),
        'snoozePresets': snoozePresets,
      };

  String encode() => jsonEncode(toJson());

  static Settings decode(String? s) {
    if (s == null || s.isEmpty) return Settings.initial();
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      final init = Settings.initial();
      final ranges = (j['ranges'] as List?)?.map((e) => ZoneRange.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      final sounds = (j['sounds'] as List?)?.map((e) => SoundCfg.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      final lines = (j['lines'] as List?)?.map((e) => LineCfg.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      final day = (j['day'] as List?)?.map((e) => LineCfg.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      final dayList = (day == null || day.isEmpty) ? init.day : day;
      for (final d in init.day) {
        // New elements appear hidden in a layout you made, except time in range.
        if (dayList.any((l) => l.id == d.id)) continue;
        if (d.id == 'name') {
          // Patient name: on top (it only shows once a name is entered).
          dayList.insert(0, d..show = true);
          continue;
        }
        dayList.add(d..show = const ['ttir', 'today', 'profile'].contains(d.id));
      }
      final presets = (j['snoozePresets'] as List?)?.map((e) => (e as num).toInt()).toList();
      // Add any night-view line that is missing (for older saved settings).
      final lineList = (lines == null || lines.isEmpty) ? init.lines : lines;
      for (final d in init.lines) {
        if (!lineList.any((l) => l.id == d.id)) lineList.add(d);
      }
      final soundList = (sounds == null || sounds.length < kSoundGroups.length) ? init.sounds : sounds;
      return Settings(
        v: Map<String, dynamic>.from((j['v'] as Map?) ?? {}),
        ranges: (ranges == null || ranges.isEmpty) ? init.ranges : ranges,
        sounds: soundList,
        lines: lineList,
        day: dayList,
        snoozePresets: presets ?? init.snoozePresets,
      );
    } catch (_) {
      return Settings.initial();
    }
  }
}
