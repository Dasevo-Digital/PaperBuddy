import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'design/theme.dart';
import 'environment.dart';
import 'file_intake.dart';
import 'notifications.dart';
import 'screens/connect_screen.dart';
import 'screens/home_shell.dart';
import 'share_intake.dart';
import 'widgets/notification_bell.dart';

class PaperBuddyApp extends StatefulWidget {
  const PaperBuddyApp({super.key, required this.state});

  final AppState state;

  @override
  State<PaperBuddyApp> createState() => _PaperBuddyAppState();
}

class _PaperBuddyAppState extends State<PaperBuddyApp>
    with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  late final _share = ShareIntake(widget.state, _navigator);

  @override
  void initState() {
    super.initState();
    _share.start();
    widget.state.notifications.onPopup = _popup;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        widget.state.appResumed();
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        widget.state.appPaused();
      default:
        break;
    }
  }

  /// Kurzer Hinweis zu einem neuen Ergebnis; er verschwindet von selbst,
  /// die Meldung bleibt in der Benachrichtigungszentrale.
  void _popup(Notice n) {
    final messenger = _messenger.currentState;
    if (messenger == null) return;
    final wide = MediaQuery.sizeOf(_messenger.currentContext!).width >= 600;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          width: wide ? 420 : null,
          duration: const Duration(seconds: 4),
          // Mit Aktionsknopf bliebe der Hinweis sonst stehen.
          persist: false,
          content: Text(
            n.kind == NoticeKind.failure
                ? '${n.title}: ${n.detail}'
                : '${n.title}: Dokument hinzugefügt',
          ),
          action: n.documentId == null || _navigator.currentState == null
              ? null
              : SnackBarAction(
                  label: 'Öffnen',
                  onPressed: () => openDocument(
                    widget.state,
                    _navigator.currentState!,
                    n.documentId!,
                  ),
                ),
        ),
      );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _share.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: widget.state.themeMode,
        builder: (context, themeMode, _) => MaterialApp(
          themeMode: themeMode,
          navigatorKey: _navigator,
          scaffoldMessengerKey: _messenger,
          title: AppEnv.appName,
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          locale: const Locale('de'),
          supportedLocales: const [Locale('de')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) {
            // Dateien auf das Fenster ziehen, um sie hochzuladen (Desktop, Web).
            Widget app = DropZone(navigator: _navigator, child: child!);
            // Entwicklungs-Builds tragen eine Schärpe, damit man sie nicht mit
            // der normalen App verwechselt.
            if (AppEnv.isDev) {
              app = Banner(
                message: 'DEV',
                location: BannerLocation.topEnd,
                color: const Color(0xFFE8590C),
                child: app,
              );
            }
            return app;
          },
          home: const _Root(),
        ),
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
