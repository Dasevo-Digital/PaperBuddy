import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'environment.dart';

/// App-Sperre per Face ID, Touch ID, Fingerabdruck oder Geräte-Code.
/// Gesperrt wird beim Start und nach [lockAfter] im Hintergrund.
class AppLock extends ChangeNotifier {
  AppLock({
    required bool enabled,
    required this.saveEnabled,
    Future<bool> Function(String reason)? authenticate,
    Future<bool> Function()? isSupported,
    this.lockAfter = const Duration(seconds: 30),
  }) : _enabled = enabled,
       _locked = enabled,
       _authenticate = authenticate ?? _deviceAuthenticate,
       _isSupported = isSupported ?? _deviceSupported;

  final Future<void> Function(bool) saveEnabled;
  final Future<bool> Function(String reason) _authenticate;
  final Future<bool> Function() _isSupported;

  /// Zeit im Hintergrund, nach der wieder gesperrt wird.
  final Duration lockAfter;

  bool _enabled;
  bool _locked;
  bool _busy = false;
  DateTime? _backgroundSince;

  /// Verdeckt den Inhalt, solange die App im App-Umschalter zu sehen ist.
  bool covered = false;

  bool get enabled => _enabled;
  bool get locked => _enabled && _locked;
  bool get busy => _busy;

  static final _auth = LocalAuthentication();

  static Future<bool> _deviceSupported() async {
    if (kIsWeb) return false;
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _deviceAuthenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> get supported => _isSupported();

  /// Einschalten nur nach erfolgreicher Prüfung, damit man sich nicht
  /// aussperrt.
  Future<bool> setEnabled(bool value) async {
    if (value &&
        !await _authenticate('App-Sperre für ${AppEnv.appName} einschalten')) {
      return false;
    }
    _enabled = value;
    _locked = false;
    await saveEnabled(value);
    notifyListeners();
    return true;
  }

  Future<void> unlock() async {
    if (_busy || !locked) return;
    _busy = true;
    notifyListeners();
    final ok = await _authenticate('${AppEnv.appName} entsperren');
    _busy = false;
    if (ok) _locked = false;
    notifyListeners();
  }

  void paused() {
    _backgroundSince ??= DateTime.now();
    if (_enabled && !covered) {
      covered = true;
      notifyListeners();
    }
  }

  /// Kurz inaktiv (App-Umschalter, Kontrollzentrum): nur verdecken.
  void inactive() {
    if (_enabled && !covered && !_busy) {
      covered = true;
      notifyListeners();
    }
  }

  void resumed() {
    final since = _backgroundSince;
    _backgroundSince = null;
    if (_enabled &&
        since != null &&
        DateTime.now().difference(since) > lockAfter) {
      _locked = true;
    }
    covered = false;
    notifyListeners();
  }
}

/// Liegt über der App, solange sie gesperrt oder verdeckt ist.
class LockOverlay extends StatelessWidget {
  const LockOverlay({super.key, required this.lock, required this.child});

  final AppLock lock;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) {
        final show = lock.locked || lock.covered;
        return Stack(
          children: [
            // Inhalt ist gesperrt nicht bedienbar und für Screenreader leer.
            ExcludeSemantics(
              excluding: show,
              child: AbsorbPointer(absorbing: show, child: child),
            ),
            if (show)
              Positioned.fill(
                child: _LockScreen(lock: lock, interactive: lock.locked),
              ),
          ],
        );
      },
    );
  }
}

class _LockScreen extends StatefulWidget {
  const _LockScreen({required this.lock, required this.interactive});

  final AppLock lock;
  final bool interactive;

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  @override
  void initState() {
    super.initState();
    // Gleich nach dem Erscheinen fragen, wie bei Banking-Apps.
    if (widget.interactive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.lock.unlock());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              Icon(
                LucideIcons.lock,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              Text(AppEnv.appName, style: theme.textTheme.headlineSmall),
              if (widget.interactive)
                FilledButton.icon(
                  onPressed: widget.lock.busy ? null : widget.lock.unlock,
                  icon: const Icon(LucideIcons.lockOpen),
                  label: const Text('Entsperren'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
