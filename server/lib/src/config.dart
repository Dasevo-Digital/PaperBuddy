import 'dart:io';

import 'package:path/path.dart' as p;

import 'backup/backup.dart';

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
    this.mailInterval = const Duration(minutes: 10),
    this.scanners,
    this.scannerDiscovery = true,
    this.storage = const StorageSettings(),
    this.filenameFormat,
    this.oauth = const OAuthSettings(),
    this.trustedProxies = const [],
    this.backup,
    this.backupDir,
    this.backupPassphrase,
    this.accessLog = true,
    this.accessLogDays = 90,
    this.invoiceFields = true,
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

  /// Abstand zwischen zwei Mail-Abrufen; `Duration.zero` = aus.
  final Duration mailInterval;

  /// Feste eSCL-Scanner: `Name=http://host/eSCL;Name2=…`
  final String? scanners;

  /// Scanner im Netz per mDNS suchen.
  final bool scannerDiscovery;

  /// Wo Originale, Archiv-PDFs und Vorschaubilder liegen.
  final StorageSettings storage;

  /// Ablage in Ordnern, z. B. `{{ created_year }}/{{ correspondent }}/{{ title }}`.
  final String? filenameFormat;

  /// OAuth-Apps für Gmail und Outlook.
  final OAuthSettings oauth;

  /// Adressen von Reverse-Proxys, deren `X-Forwarded-For` gilt.
  final List<String> trustedProxies;

  /// Zeitgesteuerte Sicherung; `null` = aus.
  final BackupSettings? backup;

  /// Zielordner und Passphrase für Sicherungen, auch ohne Zeitplan
  /// (`manage backup`).
  final String? backupDir;
  final String? backupPassphrase;

  /// Zugriffe auf Dokumente protokollieren und so viele Tage behalten.
  final bool accessLog;
  final int accessLogDays;

  /// Rechnungsdaten (Betrag, Nummer, Fälligkeit, IBAN) in Custom Fields.
  final bool invoiceFields;

  String get databasePath => p.join(dataDir, 'paperbuddy.sqlite3');

  factory Config.fromEnvironment([Map<String, String>? env]) {
    env ??= Platform.environment;
    String? get(String name) {
      final value = env!['PAPERBUDDY_$name'] ?? env['PAPERLESS_$name'];
      return (value == null || value.isEmpty) ? null : value;
    }

    final dataDir = p.absolute(get('DATA_DIR') ?? 'data');
    final passphraseFile = get('BACKUP_PASSPHRASE_FILE');
    final passphrase = get('BACKUP_PASSPHRASE') ??
        (passphraseFile == null ? null : File(passphraseFile).readAsStringSync().trim());
    final backupDir = get('BACKUP_DIR');
    final backupTime = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(get('BACKUP_TIME') ?? '03:00');
    if (backupTime == null) throw FormatException('BACKUP_TIME im Format HH:MM angeben');
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
      mailInterval: Duration(minutes: int.parse(get('MAIL_INTERVAL') ?? '10')),
      scanners: get('SCANNERS'),
      scannerDiscovery: (get('SCANNER_DISCOVERY') ?? 'true') != 'false',
      filenameFormat: get('FILENAME_FORMAT'),
      oauth: OAuthSettings(
        callbackBaseUrl: get('OAUTH_CALLBACK_BASE_URL') ?? get('URL'),
        gmailClientId: get('GMAIL_OAUTH_CLIENT_ID'),
        gmailClientSecret: get('GMAIL_OAUTH_CLIENT_SECRET'),
        outlookClientId: get('OUTLOOK_OAUTH_CLIENT_ID'),
        outlookClientSecret: get('OUTLOOK_OAUTH_CLIENT_SECRET'),
      ),
      storage: StorageSettings(
        backend: get('STORAGE_BACKEND') ?? 'local',
        cacheMb: int.parse(get('STORAGE_CACHE_MB') ?? '500'),
        s3Endpoint: get('S3_ENDPOINT'),
        s3Region: get('S3_REGION') ?? 'us-east-1',
        s3Bucket: get('S3_BUCKET'),
        s3AccessKey: get('S3_ACCESS_KEY'),
        s3SecretKey: get('S3_SECRET_KEY'),
        s3Prefix: get('S3_PREFIX') ?? '',
        s3PathStyle: (get('S3_PATH_STYLE') ?? 'true') != 'false',
        webdavUrl: get('WEBDAV_URL'),
        webdavUser: get('WEBDAV_USER'),
        webdavPassword: get('WEBDAV_PASSWORD'),
      ),
      corsOrigins: _list(get('CORS_ALLOWED_HOSTS')),
      trustedProxies: _list(get('TRUSTED_PROXIES')),
      backupDir: backupDir == null ? null : p.absolute(backupDir),
      backupPassphrase: passphrase,
      accessLog: (get('ACCESS_LOG') ?? 'true') != 'false',
      accessLogDays: int.parse(get('ACCESS_LOG_DAYS') ?? '90'),
      invoiceFields: (get('INVOICE_FIELDS') ?? 'true') != 'false',
      backup: backupDir == null || passphrase == null || passphrase.isEmpty
          ? null
          : BackupSettings(
              dir: p.absolute(backupDir),
              passphrase: passphrase,
              hour: int.parse(backupTime.group(1)!),
              minute: int.parse(backupTime.group(2)!),
              keep: int.parse(get('BACKUP_KEEP') ?? '7'),
            ),
    );
  }
}

List<String> _list(String? value) =>
    (value ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

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

class StorageSettings {
  const StorageSettings({
    this.backend = 'local',
    this.cacheMb = 500,
    this.s3Endpoint,
    this.s3Region = 'us-east-1',
    this.s3Bucket,
    this.s3AccessKey,
    this.s3SecretKey,
    this.s3Prefix = '',
    this.s3PathStyle = true,
    this.webdavUrl,
    this.webdavUser,
    this.webdavPassword,
  });

  /// `local`, `s3` oder `webdav`.
  final String backend;
  final int cacheMb;
  final String? s3Endpoint;
  final String s3Region;
  final String? s3Bucket;
  final String? s3AccessKey;
  final String? s3SecretKey;
  final String s3Prefix;
  final bool s3PathStyle;
  final String? webdavUrl;
  final String? webdavUser;
  final String? webdavPassword;
}

class OAuthSettings {
  const OAuthSettings({
    this.callbackBaseUrl,
    this.gmailClientId,
    this.gmailClientSecret,
    this.outlookClientId,
    this.outlookClientSecret,
  });

  /// Öffentliche Adresse des Servers, an die der Anbieter zurückleitet.
  final String? callbackBaseUrl;
  final String? gmailClientId;
  final String? gmailClientSecret;
  final String? outlookClientId;
  final String? outlookClientSecret;
}
