import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';

import '../config.dart';
import '../db.dart';

final _log = Logger('oauth');

/// Anbieter mit OAuth für IMAP.
class OAuthProvider {
  const OAuthProvider({
    required this.name,
    required this.accountType,
    required this.authUrl,
    required this.tokenUrl,
    required this.scope,
    required this.imapServer,
    this.extraAuthParams = const {},
  });

  final String name;

  /// `account_type` in Paperless: 2 = Gmail, 3 = Outlook.
  final int accountType;
  final String authUrl;
  final String tokenUrl;
  final String scope;
  final String imapServer;
  final Map<String, String> extraAuthParams;

  static const gmail = OAuthProvider(
    name: 'gmail',
    accountType: 2,
    authUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenUrl: 'https://oauth2.googleapis.com/token',
    scope: 'https://mail.google.com/ openid email',
    imapServer: 'imap.gmail.com',
    extraAuthParams: {'access_type': 'offline', 'prompt': 'consent'},
  );

  static const outlook = OAuthProvider(
    name: 'outlook',
    accountType: 3,
    authUrl: 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
    tokenUrl: 'https://login.microsoftonline.com/common/oauth2/v2.0/token',
    scope: 'offline_access https://outlook.office.com/IMAP.AccessAsUser.All openid email',
    imapServer: 'outlook.office365.com',
  );
}

/// OAuth-Ablauf: Anmelde-Link, Rückruf, Token erneuern.
class MailOAuth {
  MailOAuth(this.db, this.settings, {http.Client? client, Map<String, OAuthProvider>? providers})
      : _http = client ?? http.Client(),
        providers = providers ?? {'gmail': OAuthProvider.gmail, 'outlook': OAuthProvider.outlook};

  final Database db;
  final OAuthSettings settings;
  final http.Client _http;
  final Map<String, OAuthProvider> providers;
  static final _random = Random.secure();

  (String, String)? _credentials(String provider) => switch (provider) {
        'gmail' when settings.gmailClientId != null && settings.gmailClientSecret != null =>
          (settings.gmailClientId!, settings.gmailClientSecret!),
        'outlook' when settings.outlookClientId != null && settings.outlookClientSecret != null =>
          (settings.outlookClientId!, settings.outlookClientSecret!),
        _ => null,
      };

  String? get _redirectUri {
    final base = settings.callbackBaseUrl;
    return base == null ? null : '${base.replaceAll(RegExp(r'/+$'), '')}/api/oauth/callback/';
  }

  /// Anmelde-Link für einen Benutzer (in `ui_settings`), `null` wenn nicht eingerichtet.
  String? authorizationUrl(String provider, int userId) {
    final creds = _credentials(provider);
    final redirect = _redirectUri;
    final p = providers[provider];
    if (creds == null || redirect == null || p == null) return null;
    final state = List.generate(32, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    db.execute('DELETE FROM oauth_states WHERE created < ?',
        [DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String()]);
    db.execute('INSERT INTO oauth_states (state, provider, user_id, created) VALUES (?, ?, ?, ?)',
        [state, provider, userId, nowIso()]);
    return Uri.parse(p.authUrl).replace(queryParameters: {
      'response_type': 'code',
      'client_id': creds.$1,
      'redirect_uri': redirect,
      'scope': p.scope,
      'state': state,
      ...p.extraAuthParams,
    }).toString();
  }

  /// `GET /api/oauth/callback/?code=…&state=…` (öffentlich, über `state` geprüft).
  Future<Response> callback(Request request) async {
    final q = request.url.queryParameters;
    final state = q['state'];
    final row = state == null ? null : db.select('SELECT * FROM oauth_states WHERE state = ?', [state]).firstOrNull;
    if (row == null) return _page('Ungültige oder abgelaufene Anmeldung. Bitte erneut versuchen.', status: 400);
    db.execute('DELETE FROM oauth_states WHERE state = ?', [state]);
    if (q['error'] != null) return _page('Anmeldung abgebrochen: ${q['error']}', status: 400);
    final provider = providers[row['provider'] as String]!;
    final creds = _credentials(provider.name)!;
    final r = await _http.post(Uri.parse(provider.tokenUrl), body: {
      'grant_type': 'authorization_code',
      'code': q['code'] ?? '',
      'redirect_uri': _redirectUri!,
      'client_id': creds.$1,
      'client_secret': creds.$2,
    });
    if (r.statusCode != 200) {
      _log.warning('Token-Abruf bei ${provider.name} fehlgeschlagen: ${r.statusCode} ${r.body}');
      return _page('Der Anbieter hat die Anmeldung abgelehnt.', status: 502);
    }
    final tokens = jsonDecode(r.body) as Map<String, dynamic>;
    final email = _emailFrom(tokens['id_token'] as String?) ?? (throw StateError('Keine E-Mail-Adresse im Token'));
    final expiration = DateTime.now().toUtc().add(Duration(seconds: (tokens['expires_in'] as num? ?? 3600).toInt()));
    final existing = db.select('SELECT id FROM mail_accounts WHERE username = ? AND account_type = ?',
        [email, provider.accountType]).firstOrNull;
    if (existing != null) {
      db.execute(
        'UPDATE mail_accounts SET password = ?, refresh_token = COALESCE(?, refresh_token), expiration = ? WHERE id = ?',
        [tokens['access_token'], tokens['refresh_token'], expiration.toIso8601String(), existing['id']],
      );
    } else {
      var name = email;
      if (db.select('SELECT 1 FROM mail_accounts WHERE name = ?', [name]).isNotEmpty) name = '$email (${provider.name})';
      db.execute(
        'INSERT INTO mail_accounts (name, imap_server, imap_port, imap_security, username, password, account_type, '
        'refresh_token, expiration, owner) VALUES (?, ?, 993, 2, ?, ?, ?, ?, ?, ?)',
        [name, provider.imapServer, email, tokens['access_token'], provider.accountType, tokens['refresh_token'],
          expiration.toIso8601String(), row['user_id']],
      );
    }
    _log.info('Mailkonto $email über ${provider.name} verbunden');
    return _page('Das Postfach $email ist verbunden. Du kannst dieses Fenster schließen.');
  }

  /// E-Mail-Adresse aus dem ID-Token (ohne Signaturprüfung: das Token kommt
  /// direkt vom Token-Endpunkt des Anbieters über TLS).
  static String? _emailFrom(String? idToken) {
    if (idToken == null) return null;
    final parts = idToken.split('.');
    if (parts.length < 2) return null;
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
    return (payload['email'] ?? payload['preferred_username'] ?? payload['upn']) as String?;
  }

  /// Gültiges Zugriffstoken für ein OAuth-Konto, bei Bedarf erneuert.
  Future<String> accessToken(Row account) async {
    final expiration = DateTime.tryParse('${account['expiration']}');
    final token = account['password'] as String;
    if (expiration != null && expiration.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 2)))) return token;
    final provider = providers.values.firstWhere((p) => p.accountType == account['account_type']);
    final creds = _credentials(provider.name) ??
        (throw StateError('OAuth für ${provider.name} ist nicht eingerichtet (CLIENT_ID/SECRET fehlen).'));
    final refresh = account['refresh_token'] as String? ?? (throw StateError('Kein Refresh-Token; Konto neu verbinden.'));
    final r = await _http.post(Uri.parse(provider.tokenUrl), body: {
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
      'client_id': creds.$1,
      'client_secret': creds.$2,
    });
    if (r.statusCode != 200) throw StateError('Token-Erneuerung fehlgeschlagen (${r.statusCode}); Konto neu verbinden.');
    final tokens = jsonDecode(r.body) as Map<String, dynamic>;
    final newExpiration = DateTime.now().toUtc().add(Duration(seconds: (tokens['expires_in'] as num? ?? 3600).toInt()));
    db.execute(
      'UPDATE mail_accounts SET password = ?, refresh_token = COALESCE(?, refresh_token), expiration = ? WHERE id = ?',
      [tokens['access_token'], tokens['refresh_token'], newExpiration.toIso8601String(), account['id']],
    );
    return tokens['access_token'] as String;
  }

  static Response _page(String message, {int status = 200}) => Response(
        status,
        body: '<!doctype html><html lang="de"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1"><title>PaperBuddy</title>'
            '<style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;line-height:1.5}</style>'
            '</head><body><h1>PaperBuddy</h1><p>${const HtmlEscape().convert(message)}</p></body></html>',
        headers: {
          'content-type': 'text/html; charset=utf-8',
          'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
        },
      );
}
