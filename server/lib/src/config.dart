import 'dart:io';

import 'package:path/path.dart' as p;

/// Laufzeitkonfiguration, ausschließlich über Umgebungsvariablen.
///
/// Die Namen orientieren sich an Paperless-ngx (`PAPERLESS_*`), damit
/// bestehende Setups leicht umziehen können.
class Config {
  Config({
    required this.host,
    required this.port,
    required this.dataDir,
    required this.mediaDir,
    required this.consumeDir,
    required this.consumePollInterval,
    required this.ocrLanguage,
    required this.adminUser,
    required this.adminPassword,
    required this.corsOrigins,
    this.emptyTrashDelay = const Duration(days: 30),
    this.email,
    this.publicUrl,
  });

  final String host;
  final int port;

  /// Datenbank und interne Dateien.
  final String dataDir;

  /// Originale, Archiv-PDFs und Vorschaubilder.
  final String mediaDir;

  /// Eingangsordner, z. B. per SMB für Netzwerkscanner freigegeben.
  final String? consumeDir;
  final Duration consumePollInterval;

  /// Tesseract-Sprachen, z. B. `deu+eng`.
  final String ocrLanguage;

  /// Wird beim ersten Start angelegt, falls noch kein Benutzer existiert.
  final String? adminUser;
  final String? adminPassword;

  final List<String> corsOrigins;

  /// So lange bleiben gelöschte Dokumente im Papierkorb.
  final Duration emptyTrashDelay;

  /// SMTP für Workflow-E-Mails; `null` = kein Versand.
  final EmailSettings? email;

  /// Öffentliche Adresse für Links in E-Mails und Webhooks (`{doc_url}`).
  final String? publicUrl;

  String get databasePath => p.join(dataDir, 'paperbuddy.sqlite3');

  factory Config.fromEnvironment([Map<String, String>? env]) {
    env ??= Platform.environment;
    String? get(String name) {
      final value = env!['PAPERBUDDY_$name'] ?? env['PAPERLESS_$name'];
      return (value == null || value.isEmpty) ? null : value;
    }

    final dataDir = p.absolute(get('DATA_DIR') ?? 'data');
    final consume = get('CONSUMPTION_DIR') ?? get('CONSUME_DIR');
    return Config(
      host: get('BIND_ADDR') ?? '0.0.0.0',
      port: int.parse(get('PORT') ?? '8000'),
      dataDir: dataDir,
      mediaDir: p.absolute(get('MEDIA_ROOT') ?? p.join(dataDir, 'media')),
      consumeDir: consume == null || consume == 'off'
          ? null
          : p.absolute(consume),
      consumePollInterval: Duration(
        seconds: int.parse(get('CONSUMER_POLLING') ?? '5'),
      ),
      ocrLanguage: get('OCR_LANGUAGE') ?? 'deu+eng',
      adminUser: get('ADMIN_USER'),
      adminPassword: get('ADMIN_PASSWORD'),
      emptyTrashDelay: Duration(days: int.parse(get('EMPTY_TRASH_DELAY') ?? '30')),
      email: get('EMAIL_HOST') == null
          ? null
          : EmailSettings(
              host: get('EMAIL_HOST')!,
              port: int.parse(get('EMAIL_PORT') ?? '25'),
              username: get('EMAIL_HOST_USER'),
              password: get('EMAIL_HOST_PASSWORD'),
              from: get('EMAIL_FROM') ?? get('EMAIL_HOST_USER') ?? 'paperbuddy@localhost',
              ssl: get('EMAIL_USE_SSL') == 'true',
              startTls: get('EMAIL_USE_TLS') == 'true',
            ),
      publicUrl: get('URL'),
      corsOrigins: (get('CORS_ALLOWED_HOSTS') ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
    );
  }
}

class EmailSettings {
  const EmailSettings({
    required this.host,
    required this.port,
    required this.from,
    this.username,
    this.password,
    this.ssl = false,
    this.startTls = false,
  });

  final String host;
  final int port;
  final String from;
  final String? username;
  final String? password;
  final bool ssl;
  final bool startTls;
}
