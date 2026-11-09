import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/ui/settings/display_settings_screen.dart';
import 'package:glucose_monitor/ui/settings/menu_screen.dart';

void main() {
  testWidgets('search finds settings inside the small pages', (t) async {
    t.view.physicalSize = const Size(1200, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: const MenuScreen()));
    await t.enterText(find.byType(TextField), 'smb dot');
    await t.pump();
    expect(find.text('SMB dot size'), findsOneWidget);
    expect(find.text('SMB dot colour'), findsOneWidget);
    expect(find.textContaining('GRAPH › SMB AND AUTOMATIC BOLUSES'), findsOneWidget);

    await t.enterText(find.byType(TextField), 'screen saver');
    await t.pump();
    expect(find.text('Screen saver'), findsWidgets);

    await t.enterText(find.byType(TextField), 'zzzz');
    await t.pump();
    expect(find.text('No setting with these words.'), findsOneWidget);
  });

  testWidgets('every group page opens', (t) async {
    t.view.physicalSize = const Size(1200, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    for (final g in [...displayGroups(), ...graphSubGroups()]) {
      await t.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Builder(builder: (c) => Scaffold(body: ListView(children: g.rows(c))))));
      expect(t.takeException(), isNull, reason: g.title);
    }
  });
}
