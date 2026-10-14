import 'package:flutter/material.dart';

import '../logic/glucose.dart';
import '../state/app_state.dart';
import '../state/settings.dart';

const Color kBg = Color(0xFF0D1117);
const Color kCard = Color(0xFF161B22);
const Color kBorder = Color(0xFF2A313C);
const Color kLine = Color(0xFF1F2630);
const Color kText = Color(0xFFE6EDF3);
const Color kMuted = Color(0xFF9AA4B2);
const Color kAccent = Color(0xFF5BC0EB);
const Color kAmber = Color(0xFFF5A623);

ThemeData buildTheme() {
  final scheme = const ColorScheme.dark(
    primary: kAccent,
    onPrimary: kBg,
    secondary: kAccent,
    surface: kCard,
    onSurface: kText,
    error: kRed,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    appBarTheme: const AppBarTheme(backgroundColor: kBg, foregroundColor: kText, elevation: 0, centerTitle: false),
    navigationBarTheme: const NavigationBarThemeData(backgroundColor: Color(0xFF11161D), indicatorColor: Color(0xFF12303D)),
    dividerColor: kLine,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kBg,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kBorder)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kBorder)),
      labelStyle: const TextStyle(color: kMuted),
    ),
  );
}

/// Numbers: the phone's normal font with equal-width digits, so values don't
/// jump around, while the decimal point and letters keep their narrow width.
const TextStyle kMono = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

/// A titled card holding settings rows.
class Section extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  final EdgeInsets padding;
  const Section({super.key, this.title, required this.children, this.padding = const EdgeInsets.symmetric(horizontal: 14)});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(title!.toUpperCase(),
                style: const TextStyle(color: kMuted, fontSize: 12.5, letterSpacing: 0.6, fontWeight: FontWeight.w500)),
          ),
        Container(
          width: double.infinity,
          padding: padding,
          decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ]),
    );
  }
}

class _Label extends StatelessWidget {
  final String label;
  final String? hint;
  const _Label(this.label, this.hint);
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 15)),
      if (hint != null && hint!.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 2), child: Text(hint!, style: const TextStyle(color: kMuted, fontSize: 12))),
    ]);
  }
}

class RowBox extends StatelessWidget {
  final Widget child;
  final bool last;
  const RowBox({super.key, required this.child, this.last = false});
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 54),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: kLine))),
      child: child,
    );
  }
}

class SwitchRow extends StatelessWidget {
  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;
  const SwitchRow({super.key, required this.label, this.hint, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return RowBox(
      child: Row(children: [
        Expanded(child: _Label(label, hint)),
        Switch(value: value, onChanged: onChanged),
      ]),
    );
  }
}

class RoundButton extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  final String semantic;
  const RoundButton(this.text, this.onTap, {super.key, this.semantic = ''});
  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semantic,
      button: true,
      child: SizedBox(
        width: 42,
        height: 42,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
            side: const BorderSide(color: kBorder),
            foregroundColor: kText,
          ),
          child: Text(text, style: const TextStyle(fontSize: 20)),
        ),
      ),
    );
  }
}

class StepRow extends StatelessWidget {
  final String label;
  final String? hint;
  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final bool last;
  const StepRow({
    super.key,
    required this.label,
    this.hint,
    required this.value,
    required this.onMinus,
    required this.onPlus,
    this.last = false,
  });
  @override
  Widget build(BuildContext context) {
    return RowBox(
      last: last,
      child: Row(children: [
        Expanded(child: _Label(label, hint)),
        RoundButton('−', onMinus, semantic: 'Decrease $label'),
        SizedBox(
          width: 78,
          child: Text(value, textAlign: TextAlign.center, style: kMono.copyWith(fontSize: 15)),
        ),
        RoundButton('+', onPlus, semantic: 'Increase $label'),
      ]),
    );
  }
}

class ChoiceRow extends StatelessWidget {
  final String label;
  final String? hint;
  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;
  const ChoiceRow({
    super.key,
    required this.label,
    this.hint,
    required this.options,
    required this.index,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final i = index.clamp(0, options.length - 1);
    return RowBox(
      child: InkWell(
        onTap: () async {
          final picked = await showModalBottomSheet<int>(
            context: context,
            backgroundColor: kCard,
            builder: (c) => SafeArea(
              child: ListView(shrinkWrap: true, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                ),
                for (var k = 0; k < options.length; k++)
                  ListTile(
                    title: Text(options[k]),
                    trailing: k == i ? const Icon(Icons.check, color: kAccent) : null,
                    onTap: () => Navigator.pop(c, k),
                  ),
              ]),
            ),
          );
          if (picked != null) onChanged(picked);
        },
        child: Row(children: [
          Expanded(child: _Label(label, hint)),
          Flexible(
            child: Text(options[i], textAlign: TextAlign.right, style: const TextStyle(color: kAccent, fontSize: 15)),
          ),
          const Icon(Icons.chevron_right, color: kMuted),
        ]),
      ),
    );
  }
}

class LinkRow extends StatelessWidget {
  final String label;
  final String? hint;
  final VoidCallback onTap;
  final IconData? icon;
  const LinkRow({super.key, required this.label, this.hint, required this.onTap, this.icon});
  @override
  Widget build(BuildContext context) {
    return RowBox(
      child: InkWell(
        onTap: onTap,
        child: Row(children: [
          if (icon != null) Padding(padding: const EdgeInsets.only(right: 12), child: Icon(icon, color: kMuted)),
          Expanded(child: _Label(label, hint)),
          const Icon(Icons.chevron_right, color: kMuted),
        ]),
      ),
    );
  }
}

/// A row of mutually exclusive options.
class Seg extends StatelessWidget {
  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;
  const Seg({super.key, required this.options, required this.index, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        for (var i = 0; i < options.length; i++) ButtonSegment<int>(value: i, label: Text(options[i], textAlign: TextAlign.center)),
      ],
      selected: {index.clamp(0, options.length - 1)},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// A settings screen whose rows are rebuilt every time a setting changes.
class SettingsPage extends StatelessWidget {
  final String title;
  final List<Widget> Function(BuildContext context) builder;
  final List<Widget>? actions;
  const SettingsPage({super.key, required this.title, required this.builder, this.actions});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: ListenableBuilder(
        listenable: app,
        builder: (c, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: builder(c),
        ),
      ),
    );
  }
}

// ---------- rows bound directly to a setting ----------

Widget setSwitch(String label, String key, {String? hint}) => SwitchRow(
      label: label,
      hint: hint,
      value: app.settings.flag(key),
      onChanged: (v) => app.change((s) => s.set(key, v)),
    );

Widget setInt(String label, String key, {required int step, required int min, required int max, String unit = '', String? hint}) {
  final v = app.settings.integer(key);
  return StepRow(
    label: label,
    hint: hint,
    value: unit.isEmpty ? '$v' : '$v $unit',
    onMinus: () => app.change((s) => s.set(key, (v - step).clamp(min, max))),
    onPlus: () => app.change((s) => s.set(key, (v + step).clamp(min, max))),
  );
}

/// Glucose setting shown in the user's units; stored in mg/dL.
Widget setMg(String label, String key, {double min = 40, double max = 400, String? hint}) {
  final v = app.settings.number(key);
  final step = app.mmol ? mgPerMmol / 10 : 1.0;
  return StepRow(
    label: label,
    hint: hint,
    value: '${fmtBg(v, app.mmol)} ${app.mmol ? 'mmol' : 'mg'}',
    onMinus: () => app.change((s) => s.set(key, (v - step).clamp(min, max))),
    onPlus: () => app.change((s) => s.set(key, (v + step).clamp(min, max))),
  );
}

Widget setTime(String label, String key, {String? hint}) {
  final v = app.settings.integer(key);
  return StepRow(
    label: label,
    hint: hint,
    value: fmtMinutesOfDay(v, app.settings.flag('time24')),
    onMinus: () => app.change((s) => s.set(key, (v + 1410) % 1440)),
    onPlus: () => app.change((s) => s.set(key, (v + 30) % 1440)),
  );
}

Widget setChoice(String label, String key, List<String> options, {String? hint}) => ChoiceRow(
      label: label,
      hint: hint,
      options: options,
      index: app.settings.integer(key),
      onChanged: (i) => app.change((s) => s.set(key, i)),
    );

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// Colours offered wherever a colour can be chosen.
const Map<String, int> kSwatches = {
  'White': 0xFFE6EDF3,
  'Light grey': 0xFFC4CCD6,
  'Grey': 0xFF9AA4B2,
  'Dark grey': 0xFF5C6672,
  'Blue': 0xFF5BC0EB,
  'Deep blue': 0xFF3D7BF7,
  'Teal': 0xFF2EC4B6,
  'Green': 0xFF3DBE7A,
  'Lime': 0xFF9BE15D,
  'Yellow': 0xFFF2C94C,
  'Orange': 0xFFF5A623,
  'Coral': 0xFFFF7A59,
  'Red': 0xFFFF4D5A,
  'Dark red': 0xFFC62834,
  'Pink': 0xFFF08BD0,
  'Purple': 0xFFB39DFF,
};

/// A row of round colour buttons. With [onZone], the first button means
/// "follow the zone colour" (green, yellow or red).
class ColorPick extends StatelessWidget {
  final int value;
  final bool zoneSelected;
  final ValueChanged<int> onPick;
  final VoidCallback? onZone;
  final double dot;
  const ColorPick({super.key, required this.value, required this.onPick, this.onZone, this.zoneSelected = false, this.dot = 36});

  @override
  Widget build(BuildContext context) {
    Widget circle({required bool selected, required String label, required VoidCallback onTap, required Widget fill}) => Semantics(
          label: label,
          button: true,
          selected: selected,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: selected ? Colors.white : kBg, width: 3),
              ),
              child: ClipOval(child: fill),
            ),
          ),
        );
    return Wrap(spacing: 6, runSpacing: 6, children: [
      if (onZone != null)
        circle(
          selected: zoneSelected,
          label: 'Zone colour',
          onTap: onZone!,
          fill: Row(children: [
            Expanded(child: Container(color: kGreen)),
            Expanded(child: Container(color: kYellow)),
            Expanded(child: Container(color: kRed)),
          ]),
        ),
      for (final e in kSwatches.entries)
        circle(
          selected: !zoneSelected && value == e.value,
          label: e.key,
          onTap: () => onPick(e.value),
          fill: Container(color: Color(e.value)),
        ),
    ]);
  }
}
