import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';

/// Adresse des Clients. `X-Forwarded-For` zählt nur, wenn die Anfrage direkt
/// von einem eingetragenen Reverse-Proxy kommt (`TRUSTED_PROXIES`, wie bei
/// Paperless-ngx); sonst könnte jeder Client sich eine Adresse ausdenken.
class ClientAddress {
  const ClientAddress({this.trustedProxies = const []});

  final List<String> trustedProxies;

  /// Hinter dem Proxy gilt der *letzte* Eintrag in `X-Forwarded-For`: Den
  /// hängt der Proxy selbst an, alles davor stammt vom Client.
  String of(Request request) {
    final peer = _peer(request)?.address;
    if (peer != null && trustedProxies.contains(peer)) {
      final hops = [
        for (final hop in request.headers['x-forwarded-for']?.split(',') ?? const <String>[])
          if (hop.trim().isNotEmpty) hop.trim(),
      ];
      if (hops.isNotEmpty) return hops.last;
    }
    return peer ?? 'unknown';
  }

  static InternetAddress? _peer(Request request) =>
      (request.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress;
}

/// Anmeldung gesperrt; [retryAfter] gibt die Wartezeit an.
class LoginThrottled implements Exception {
  LoginThrottled(this.retryAfter);
  final Duration retryAfter;
}

/// Bremst das Durchprobieren von Passwörtern: Nach wiederholten Fehlern
/// verdoppelt sich die Wartezeit (höchstens eine Stunde). Gezählt wird
/// dreifach:
///
/// * je Adresse und Benutzername ([freeAttempts]) – jemand vertippt sich,
/// * je Adresse über alle Benutzernamen ([addressAttempts]) – viele Konten
///   mit wenigen Passwörtern („Password Spraying“),
/// * je Benutzername über alle Adressen ([accountAttempts]) – ein Konto von
///   vielen Rechnern aus.
///
/// Mit der letzten Zählung könnte jeder, der einen Benutzernamen kennt, den
/// Inhaber aussperren. Adressen, die sich innerhalb von [trustFor] erfolgreich
/// bei diesem Konto angemeldet haben, sind davon deshalb ausgenommen; die
/// beiden anderen Grenzen gelten für sie weiter.
class LoginThrottle {
  LoginThrottle({
    this.freeAttempts = 5,
    this.addressAttempts = 20,
    this.accountAttempts = 20,
    this.trustFor = const Duration(days: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int freeAttempts;
  final int addressAttempts;
  final int accountAttempts;
  final Duration trustFor;
  final DateTime Function() _clock;
  final _failures = <String, _Failures>{};

  /// Letzte erfolgreiche Anmeldung je „Adresse|Benutzer“.
  final _trusted = <String, DateTime>{};

  static const _maxBlock = Duration(hours: 1);

  /// So lange nach dem letzten Fehler werden Fehler vergessen.
  static const _forgetAfter = Duration(hours: 1);

  /// Obergrenze gemerkter Einträge; aktive Sperren werden nie verworfen.
  static const _maxEntries = 10000;

  /// Verbleibende Sperrzeit oder `null`, wenn ein Versuch erlaubt ist.
  Duration? blockedFor(String address, String username) {
    final now = _clock();
    Duration? longest;
    final trusted = _isTrusted(address, username, now);
    for (final key in _keys(address, username)) {
      if (trusted && key.startsWith('account|')) continue;
      final until = _failures[key]?.blockedUntil;
      if (until == null || !until.isAfter(now)) continue;
      final left = until.difference(now);
      if (longest == null || left > longest) longest = left;
    }
    return longest;
  }

  void failed(String address, String username) {
    final now = _clock();
    final keys = _keys(address, username);
    final limits = [freeAttempts, addressAttempts, accountAttempts];
    for (var i = 0; i < keys.length; i++) {
      final previous = _failures[keys[i]];
      final stale = previous == null ||
          now.difference(previous.last) > _forgetAfter && !(previous.blockedUntil?.isAfter(now) ?? false);
      final count = (stale ? 0 : previous.count) + 1;
      DateTime? until;
      if (count >= limits[i]) {
        final seconds = min(30 * pow(2, min(count - limits[i], 12)).toInt(), _maxBlock.inSeconds);
        until = now.add(Duration(seconds: seconds));
      }
      _failures[keys[i]] = _Failures(count, until, now);
    }
    if (_failures.length > _maxEntries) _prune(now);
  }

  /// Eine erfolgreiche Anmeldung vergibt die Fehler dieser Adresse bei diesem
  /// Konto (nicht die Zählungen über alle Konten oder Adressen).
  void succeeded(String address, String username) {
    final key = _keys(address, username).first;
    _failures.remove(key);
    final now = _clock();
    _trusted[key] = now;
    if (_trusted.length > _maxEntries) {
      _trusted.removeWhere((_, at) => now.difference(at) > trustFor);
      if (_trusted.length > _maxEntries) {
        final oldest = _trusted.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
        for (final e in oldest.take(_trusted.length - _maxEntries)) {
          _trusted.remove(e.key);
        }
      }
    }
  }

  bool _isTrusted(String address, String username, DateTime now) {
    final at = _trusted[_keys(address, username).first];
    return at != null && now.difference(at) <= trustFor;
  }

  /// Verwirft vergessene, dann die ältesten ungesperrten Einträge – nie eine
  /// aktive Sperre, damit erfundene Namen keine Sperre aufheben.
  void _prune(DateTime now) {
    _failures.removeWhere(
      (_, f) => now.difference(f.last) > _forgetAfter && !(f.blockedUntil?.isAfter(now) ?? false),
    );
    if (_failures.length <= _maxEntries) return;
    final unblocked = _failures.entries.where((e) => !(e.value.blockedUntil?.isAfter(now) ?? false)).toList()
      ..sort((a, b) => a.value.last.compareTo(b.value.last));
    for (final e in unblocked.take(_failures.length - _maxEntries)) {
      _failures.remove(e.key);
    }
  }

  static List<String> _keys(String address, String username) {
    final name = username.trim().toLowerCase();
    return ['$address|$name', 'address|$address', 'account|$name'];
  }
}

class _Failures {
  _Failures(this.count, this.blockedUntil, this.last);

  final int count;
  final DateTime? blockedUntil;
  final DateTime last;
}

/// Sicherheits-Header für jede Antwort. Die API liefert JSON und Dateien,
/// keine eigenen Seiten; darum darf nichts nachgeladen, eingebettet oder
/// ausgeführt werden. Eine Antwort, die selbst eine `Content-Security-Policy`
/// setzt (die OAuth-Rückrufseite), behält ihre.
Middleware securityHeaders({bool hsts = false}) => (inner) => (request) async {
  final response = await inner(request);
  return response.change(headers: {
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer',
    if (!response.headers.containsKey('content-security-policy'))
      'content-security-policy': contentSecurityPolicy,
    'cross-origin-opener-policy': 'same-origin',
    if (hsts) 'strict-transport-security': 'max-age=31536000',
  });
};

const contentSecurityPolicy =
    "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";
