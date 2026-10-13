import 'package:flutter/material.dart';

import 'state/app_state.dart';
import 'ui/common.dart';
import 'ui/connect_screen.dart';
import 'ui/home_screen.dart';

final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await app.init(navKey);
  runApp(const GlucoseApp());
}

class GlucoseApp extends StatelessWidget {
  const GlucoseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navKey,
      title: 'Glucose Monitor',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: ListenableBuilder(
        listenable: app,
        builder: (c, _) => app.settings.str('nsUrl').isEmpty ? const ConnectScreen() : const HomeScreen(),
      ),
    );
  }
}
