import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'logic/glucose.dart';
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

/// How much bigger to draw everything. Auto: phones 100%, tablets larger.
double uiScaleFor(Size screen) {
  final pct = app.settings.integer('uiScale');
  if (pct > 0) return pct / 100.0;
  final side = screen.shortestSide;
  if (side < 600) return 1.0;
  // A computer's browser window (wider than tall): keep the normal size.
  if (kIsWeb && screen.width > screen.height) return 1.0;
  return (side / 430.0).clamp(1.0, 2.0);
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
      // Scales the whole app (text, buttons, graph, night view) on tablets,
      // so it looks like the phone version, only bigger.
      builder: (context, child) => ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final mq = MediaQuery.of(context);
          final s = uiScaleFor(mq.size);
          final logical = mq.size / s;
          Widget scaled = FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: logical.width,
              height: logical.height,
              child: MediaQuery(
                data: mq.copyWith(
                  size: logical,
                  padding: mq.padding / s,
                  viewPadding: mq.viewPadding / s,
                  viewInsets: mq.viewInsets / s,
                  devicePixelRatio: mq.devicePixelRatio * s,
                ),
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          );
          // Browser tab (and the phone's app switcher): the latest glucose,
          // e.g. "7.4 ↗ +0.1".
          final l = app.latest;
          final tabTitle = l == null
              ? 'Glucose Monitor'
              : '${app.isStale ? '⚠ ' : ''}${fmtBg(l.mg, app.mmol)} ${arrowText(l.direction)}'
                  '${app.delta5 == null ? '' : ' ${fmtDelta(app.delta5!, app.mmol)}'}'
                  '${app.isStale && app.age != null ? ' (${fmtAge(app.age!)})' : ''}';
          scaled = Title(title: tabTitle, color: const Color(0xFF0D1117), child: scaled);
          if (!kIsWeb) return scaled;
          // In a browser, the first click or tap allows alarm sounds.
          return Listener(onPointerDown: (_) => app.player.unlock(), child: scaled);
        },
      ),
      home: ListenableBuilder(
        listenable: app,
        builder: (c, _) => app.settings.str('nsUrl').isEmpty ? const ConnectScreen() : const HomeScreen(),
      ),
    );
  }
}
