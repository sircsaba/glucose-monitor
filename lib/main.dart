import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ApplicationSwitcherDescription, SystemChrome;

import 'logic/glucose.dart';
import 'plus.dart';
import 'state/app_state.dart';
import 'ui/common.dart';
import 'ui/connect_screen.dart';
import 'ui/home_screen.dart';

final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await app.init(navKey);
  } catch (e) {
    debugPrint('init: $e');
  }
  // Browser tab (and the phone's app switcher): the latest glucose, e.g.
  // "7.4 ↗ +0.1". Set straight away on each update, not when the screen is
  // redrawn: a browser does not redraw a tab you are not looking at.
  app.addListener(_updateTitle);
  try {
    _updateTitle();
  } catch (_) {}
  runApp(const GlucoseApp());
}

String _lastTitle = '';

void _updateTitle() {
  final l = app.latest;
  final t = l == null
      ? kAppName
      : '${app.isStale ? '⚠ ' : ''}${fmtBg(l.mg, app.mmol)} ${arrowText(l.direction)}'
          '${app.delta5 == null ? '' : ' ${fmtDelta(app.delta5!, app.mmol)}'}'
          '${app.isStale && app.age != null ? ' (${fmtAge(app.age!)})' : ''}';
  if (t == _lastTitle) return;
  _lastTitle = t;
  SystemChrome.setApplicationSwitcherDescription(
      ApplicationSwitcherDescription(label: t, primaryColor: 0xFF0D1117));
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
      title: kAppName,
      onGenerateTitle: (_) => _lastTitle,
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
