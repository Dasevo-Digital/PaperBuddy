import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'design/theme.dart';
import 'environment.dart';
import 'screens/connect_screen.dart';
import 'screens/home_shell.dart';

class PaperBuddyApp extends StatelessWidget {
  const PaperBuddyApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
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
