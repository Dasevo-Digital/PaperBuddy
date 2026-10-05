import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'design/theme.dart';
import 'environment.dart';
import 'screens/connect_screen.dart';
import 'screens/home_shell.dart';
import 'share_intake.dart';

class PaperBuddyApp extends StatefulWidget {
  const PaperBuddyApp({super.key, required this.state});

  final AppState state;

  @override
  State<PaperBuddyApp> createState() => _PaperBuddyAppState();
}

class _PaperBuddyAppState extends State<PaperBuddyApp> {
  final _navigator = GlobalKey<NavigatorState>();
  late final _share = ShareIntake(widget.state, _navigator);

  @override
  void initState() {
    super.initState();
    _share.start();
  }

  @override
  void dispose() {
    _share.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: MaterialApp(
        navigatorKey: _navigator,
        title: AppEnv.appName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: switch (state.status) {
        SessionStatus.starting => const Scaffold(
          key: ValueKey('starting'),
          body: Center(child: CircularProgressIndicator()),
        ),
        SessionStatus.signedOut => const ConnectScreen(
          key: ValueKey('connect'),
        ),
        SessionStatus.signedIn => const HomeShell(key: ValueKey('home')),
      },
    );
  }
}
