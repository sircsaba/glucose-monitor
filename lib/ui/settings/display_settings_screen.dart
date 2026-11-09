import 'package:flutter/material.dart';

import '../../logic/glucose.dart';
import '../../state/app_state.dart';
import '../../state/settings.dart';
import '../bg_chart.dart';
import '../common.dart';

/// Hours a graph button can show.
const _hourChoices = [1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 18, 24];

const _scales = [0, 60, 70, 80, 90, 100, 115, 130, 150, 175, 200];
const _scaleLabels = ['Auto', '60%', '70%', '80%', '90%', '100%', '115%', '130%', '150%', '175%', '200%'];

String _onOff(String key) => app.settings.flag(key) ? 'on' : 'off';

class DisplaySettingsScreen extends StatelessWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => GroupedSettingsPage(title: 'Display & graph', groups: displayGroups);
}

/// The groups of Display & graph (also searched from the Settings menu).
List<SettingsGroup> displayGroups() => [
      SettingsGroup('Patient', icon: Icons.person_outline, summary: () {
        final n = app.settings.str('patientName').trim();
        return n.isEmpty ? 'No name shown' : n;
      }, rows: (_) => [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: TextFormField(
                initialValue: app.settings.str('patientName'),
                decoration: const InputDecoration(labelText: 'Name shown above the glucose (empty: none)'),
                onChanged: (v) => app.change((x) => x.set('patientName', v)),
              ),
            ),
          ]),
      SettingsGroup('Units', icon: Icons.straighten, summary: () => app.settings.mmol ? 'mmol/L' : 'mg/dL', rows: (_) => [
            ChoiceRow(
              label: 'Glucose units',
              options: const ['mmol/L', 'mg/dL'],
              index: app.settings.mmol ? 0 : 1,
              onChanged: (i) => app.change((x) => x.set('mmol', i == 0)),
            ),
          ]),
      SettingsGroup('Buttons above the graph', icon: Icons.schedule, summary: () => '${app.graphButtons.take(5).join(', ')} h', rows: (_) => _buttonRows()),
      graphGroup(),
      SettingsGroup('Brightness', icon: Icons.brightness_6_outlined,
          summary: () => app.settings.flag('dimOn') ? 'Dimmed ${app.settings.integer('dimPct')}%' : 'Normal', rows: (_) => [
                setSwitch('Dim the screen', 'dimOn', hint: 'Same as the brightness button on the main screen'),
                setInt('Darker by', 'dimPct', step: 10, min: 10, max: 90, unit: '%'),
              ]),
      screenSaverGroup(),
      SettingsGroup('Screen size and layout', icon: Icons.aspect_ratio, summary: () {
        final i = _scales.indexOf(app.settings.integer('uiScale')).clamp(0, _scales.length - 1);
        return 'Size ${_scaleLabels[i]} · ${const ['Auto', 'Computer', 'Phone'][app.settings.integer('screenMode').clamp(0, 2)]} layout';
      }, rows: (_) => [
            ChoiceRow(
              label: 'Size of everything',
              hint: 'Auto makes the app larger on a tablet',
              options: _scaleLabels,
              index: _scales.indexOf(app.settings.integer('uiScale')).clamp(0, _scales.length - 1),
              onChanged: (i) => app.change((x) => x.set('uiScale', _scales[i])),
            ),
            setChoice('Layout', 'screenMode', const ['Auto', 'Computer', 'Phone'],
                hint: 'Computer: one wide page that fits the screen (big glucose, cards on one line, graph filling the rest). '
                    'Auto picks Computer on a laptop or desktop in landscape'),
            setSwitch('Phone on its side: split the screen', 'landSplit', hint: 'Values on the left, graph on the right'),
            setInt('Width of the values side', 'splitLeft', step: 5, min: 25, max: 70, unit: '%'),
            setChoice('Bottom bar (Live, Treat…)', 'navCompact', const ['Thin on a computer', 'Always thin', 'Always normal'],
                hint: 'Thin leaves more room for the graph'),
          ]),
      SettingsGroup('Reports', icon: Icons.insert_chart_outlined,
          summary: () => 'Time in range ${fmtBg(app.settings.number('tirLo'), app.mmol)}–${fmtBg(app.settings.number('tirHi'), app.mmol)}',
          rows: (_) => [
                setMg('Range from', 'tirLo', min: 54, max: 140),
                setMg('Range to', 'tirHi', min: 120, max: 300),
              ]),
    ];

List<Widget> _buttonRows() {
  final s = app.settings;
  final buttons = List<int>.from(app.graphButtons);
  while (buttons.length < 5) {
    buttons.add(24);
  }
  void setButton(int i, int dir) {
    var k = _hourChoices.indexOf(buttons[i]);
    if (k < 0) k = 0;
    k = (k + dir).clamp(0, _hourChoices.length - 1);
    final list = List<int>.from(buttons);
    list[i] = _hourChoices[k];
    app.change((x) {
      x.set('graphButtons', list);
      if (!list.contains(x.integer('graphHours'))) x.set('graphHours', list[0]);
    });
  }

  return [
    for (var i = 0; i < 5; i++)
      StepRow(label: 'Button ${i + 1}', value: '${buttons[i]} h', onMinus: () => setButton(i, -1), onPlus: () => setButton(i, 1)),
    ChoiceRow(
      label: 'Selected when the app opens',
      options: [for (final h in buttons.take(5)) '$h hours'],
      index: buttons.indexOf(s.integer('graphHours')).clamp(0, 4),
      onChanged: (i) => app.change((x) => x.set('graphHours', buttons[i])),
    ),
    LinkRow(
      label: 'Back to 1, 2, 3, 6 and 12 hours',
      onTap: () => app.change((x) {
        x.set('graphButtons', [1, 2, 3, 6, 12]);
        x.set('graphHours', 3);
      }),
    ),
  ];
}

/// The graph: a few main choices, and a small page for each kind of marker.
SettingsGroup graphGroup() => SettingsGroup('Graph', icon: Icons.show_chart, summary: () {
      final top = app.settings.number('graphTop');
      final dots = const ['small', 'medium', 'large', 'extra large'][app.settings.integer('dotSize').clamp(0, 3)];
      return 'Top ${top <= 0 ? 'auto' : fmtBg(top, app.mmol)} · $dots dots · prediction ${_onOff('showPrediction')}';
    }, rows: (_) {
      final s = app.settings;
      // Top of the graph: auto, or a fixed value (stored in mg/dL).
      final topsMmol = [0.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0];
      final topsMg = [0.0, 180.0, 200.0, 240.0, 280.0, 320.0, 400.0];
      final tops = s.mmol ? topsMmol.map((v) => v * mgPerMmol).toList() : topsMg;
      final topLabels = (s.mmol ? topsMmol : topsMg).map((v) => v == 0 ? 'Auto' : v.toStringAsFixed(0)).toList();
      var topIndex = 0;
      for (var i = 0; i < tops.length; i++) {
        if ((tops[i] - s.number('graphTop')).abs() < 1) topIndex = i;
      }
      return [
        ChoiceRow(
          label: 'Top of graph',
          hint: 'Auto: just above your high line, higher when readings go above it',
          options: topLabels,
          index: topIndex,
          onChanged: (i) => app.change((x) => x.set('graphTop', tops[i])),
        ),
        setChoice('Graph height', 'graphFit', const ['Fit the screen on a computer', 'Always fit the screen', 'Fixed (set in Day view layout)'],
            hint: 'Fit: the graph uses the room left, so the whole page shows without scrolling'),
        setChoice('Dot size', 'dotSize', const ['Small', 'Medium', 'Large', 'Extra large']),
        setSwitch('Prediction', 'showPrediction'),
        for (final g in graphSubGroups()) GroupRow(g),
      ];
    });

/// The small pages under Graph.
List<SettingsGroup> graphSubGroups() => [
      SettingsGroup('Boluses and carbs', summary: () => 'Shown ${_onOff('showTreatments')} · ${app.settings.integer('treatSize')}%',
          rows: (_) => treatmentSettings()),
      SettingsGroup('SMB and automatic boluses', summary: () {
        final s = app.settings;
        if (!s.flag('smbShow')) return 'Not shown';
        return 'Dots ${s.integer('smbDotSize')}% · amounts ${_onOff('smbLabels')}';
      }, rows: (_) => smbSettings()),
      SettingsGroup('Basal', summary: () => app.settings.flag('showBasal')
          ? (app.settings.integer('basalPos') == 0 ? 'At the top' : 'Under the graph')
          : 'Not shown', rows: (_) => basalSettings()),
      SettingsGroup('Presets and profile', summary: () => 'Presets ${_onOff('presetShow')} · profile ${_onOff('profileShow')}',
          rows: (_) => presetSettings()),
      SettingsGroup('Grid and time lines', summary: () => 'Grid ${_onOff('gridLines')}', rows: (_) => gridSettings()),
      SettingsGroup('Glucose dot colours', summary: () => 'Brightness ${app.settings.integer('dotBright')}%', rows: (_) => dotSettings()),
      SettingsGroup('Time in tight range', summary: () => app.settings.flag('ttirOn')
          ? 'On, up to ${fmtBg(app.settings.number('ttirHi'), app.mmol)}'
          : 'Off', rows: (_) => ttirSettings()),
      SettingsGroup('Touching the graph', summary: () => 'Reading: ${const ['nothing', 'value', 'value and time', 'time'][app.settings.integer('tipBg').clamp(0, 3)]}',
          rows: (_) => tooltipSettings()),
    ];

/// Screen saver: the glucose drifting on a black screen, alarms quiet.
SettingsGroup screenSaverGroup() => SettingsGroup('Screen saver', icon: Icons.screenshot_monitor_outlined,
        hint: 'A black screen with only the glucose moving slowly. Alarms stay quiet while it is on; touch the screen to come back. '
            'Each phone and tablet has its own setting.', summary: () {
      final s = app.settings;
      final t24 = s.flag('time24');
      if (!s.flag('ssAutoOn')) return 'With the button on the main screen';
      return 'Every day at ${fmtMinutesOfDay(s.integer('ssFrom'), t24)}'
          '${s.flag('ssEndOn') ? ' until ${fmtMinutesOfDay(s.integer('ssTo'), t24)}' : ', until touched'}';
    }, rows: (_) => [
          setSwitch('Start every day', 'ssAutoOn', hint: 'When the app is open at this time (for example when you get up)'),
          setTime('At', 'ssFrom'),
          setSwitch('End at a set time', 'ssEndOn', hint: 'Off: stays on until the screen is touched'),
          if (app.settings.flag('ssEndOn')) setTime('Until', 'ssTo'),
          setSwitch('Urgent low still rings', 'ssUrgentLow', hint: 'Red low zone: rings and brings the app back. Strongly suggested'),
          setInt('Brightness of the glucose', 'ssBright', step: 5, min: 5, max: 100, unit: '%'),
          setSwitch('Zone colours', 'ssZoneColor', hint: 'Off: plain grey'),
          LinkRow(label: 'Start the screen saver now', onTap: app.startScreenSaver),
        ]);
