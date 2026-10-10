import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:sqlite3/sqlite3.dart';

import 'access.dart';
import 'access_log.dart';
import 'backup/backup.dart';
import 'api/custom_fields.dart';
import 'api/paperless_api.dart';
import 'auth.dart';
import 'config.dart';
import 'filenames.dart';
import 'history.dart';
import 'db.dart';
import 'processing/consume_folder.dart';
import 'processing/consumer.dart';
import 'processing/pdf_ops.dart';
import 'processing/tools.dart';
import 'mail/mail_service.dart';
import 'mail/oauth.dart';
import 'scanners/escl.dart';
import 'storage.dart';
import 'storage_remote.dart';
import 'trash.dart';
import 'workflows.dart';
import 'version.dart';
import 'reminders.dart';
import 'security.dart';

final _log = Logger('server');

/// Setzt alle Teile zusammen; auch von den Tests genutzt.
class PaperbuddyServer {
  PaperbuddyServer._({
    required this.config,
    required this.db,
    required this.auth,
    required this.access,
    required this.store,
    required this.consumer,
    required this.trash,
    required this.handler,
    required this.watcher,
    required this.workflows,
    required this.mail,
    required this.scanners,
    required this.reminders,
    required this.backups,
    required this.accessLog,
  });

  final Config config;
  final Database db;
  final AuthService auth;
  final Access access;
  final BlobStore store;
  final Consumer consumer;
  final Trash trash;
  final Handler handler;
  final ConsumeFolderWatcher? watcher;
  final WorkflowEngine workflows;
  final MailService mail;
  final Reminders reminders;
  final ScannerService scanners;
  final BackupService backups;
  final AccessLog accessLog;
  HttpServer? _http;
  Timer? _trainTimer;

  static Future<PaperbuddyServer> create(Config config, {Database? database, BlobStore? store}) async {
    final db = database ?? openDatabase(config.databasePath);
    final auth = AuthService(db);
    if (!auth.hasUsers && config.adminUser != null && config.adminPassword != null) {
      auth.createUser(config.adminUser!, config.adminPassword!, superuser: true);
      _log.info('Administrator "${config.adminUser}" angelegt');
    }
    final access = Access(db);
    final tools = ExternalTools(ocrLanguage: config.ocrLanguage);
    store ??= await createStore(config);
    final history = History(db);
    final consumer = Consumer(db: db, store: store, tools: tools, workDir: p.join(config.dataDir, 'work'), history: history);
    final trash = Trash(db, store, access, delay: config.emptyTrashDelay);
    final customFields = CustomFieldsResource(db, access);
    final workflows = WorkflowEngine(
      db: db,
      access: access,
      store: store,
      customFields: customFields,
      history: history,
      email: config.email,
      publicUrl: config.publicUrl,
    );
    consumer.hooks = workflows;
    final filenames = FilenameGenerator(db, store, format: config.filenameFormat);
    consumer.onStored = filenames.relocate;
    final oauth = MailOAuth(db, config.oauth);
    final mail = MailService(
      oauth: oauth,
      db: db,
      access: access,
      consumer: consumer,
      workDir: p.join(config.dataDir, 'work'),
      interval: config.mailInterval,
    );
    final scanners = ScannerService(
      access: access,
      consumer: consumer,
      workDir: p.join(config.dataDir, 'work'),
      configured: ScannerService.parseConfig(config.scanners),
      discover: config.scannerDiscovery,
    );
    final reminders = Reminders(
      db: db,
      access: access,
      email: config.email,
      publicUrl: config.publicUrl,
    );
    final backups = BackupService(
      db: db,
      store: store,
      workDir: p.join(config.dataDir, 'work'),
      settings: config.backup,
      statusFile: p.join(config.dataDir, 'backup-status.json'),
    );
    final accessLog = AccessLog(
      db,
      enabled: config.accessLog,
      retention: Duration(days: config.accessLogDays),
    );
    final api = PaperlessApi(
      db: db,
      auth: auth,
      access: access,
      store: store,
      consumer: consumer,
      tools: tools,
      trash: trash,
      customFields: customFields,
      history: history,
      pdf: PdfOperations(db: db, store: store, tools: tools, consumer: consumer, workDir: p.join(config.dataDir, 'work')),
      extraRoutes: [workflows.mount, mail.mount, scanners.mount, reminders.mount],
      onLabelUpdated: (table, id) async {
        // Betroffene Dokumente mit neuem Namen ablegen.
        final sql = switch (table) {
          'tags' => 'SELECT document_id AS id FROM document_tags WHERE tag_id = ?',
          'correspondents' => 'SELECT id FROM documents WHERE correspondent_id = ?',
          'document_types' => 'SELECT id FROM documents WHERE document_type_id = ?',
          _ => 'SELECT id FROM documents WHERE storage_path_id = ?',
        };
        for (final r in db.select(sql, [id])) {
          await filenames.relocate(r['id'] as int);
        }
      },
      onDocumentUpdated: (id) async {
        await workflows.documentUpdated(id);
        await filenames.relocate(id);
      },
      oauthUrls: (user) => {
        'gmail': oauth.authorizationUrl('gmail', user.id),
        'outlook': oauth.authorizationUrl('outlook', user.id),
      },
      corsOrigins: config.corsOrigins,
      clientAddress: ClientAddress(trustedProxies: config.trustedProxies),
      hsts: config.publicUrl?.startsWith('https://') ?? false,
      backups: backups,
      accessLog: accessLog,
    );
    final watcher = config.consumeDir == null
        ? null
        : ConsumeFolderWatcher(config.consumeDir!, consumer, interval: config.consumePollInterval);
    return PaperbuddyServer._(
      config: config,
      db: db,
      auth: auth,
      access: access,
      store: store,
      consumer: consumer,
      trash: trash,
      handler: api.handler,
      watcher: watcher,
      workflows: workflows,
      mail: mail,
      scanners: scanners,
      reminders: reminders,
      backups: backups,
      accessLog: accessLog,
    );
  }

  Future<void> serve() async {
    final missing = (await ExternalTools(ocrLanguage: config.ocrLanguage).report())
        .entries
        .where((e) => !e.value)
        .map((e) => e.key);
    if (missing.isNotEmpty) {
      _log.warning('Nicht gefunden: ${missing.join(', ')}. OCR und Vorschaubilder sind eingeschränkt.');
    }
    if (!auth.hasUsers) {
      _log.warning('Noch kein Benutzer vorhanden. PAPERBUDDY_ADMIN_USER und PAPERBUDDY_ADMIN_PASSWORD '
          'setzen oder `dart run bin/manage.dart createsuperuser` ausführen.');
    }
    watcher?.start();
    trash.startAutoEmpty();
    workflows.startScheduler();
    reminders.start();
    backups.start();
    if (config.accessLog) accessLog.start();
    if (config.backupDir != null && config.backup == null) {
      _log.warning('PAPERBUDDY_BACKUP_DIR ist gesetzt, aber keine Passphrase: keine Sicherung.');
    } else if (config.backupDir == null) {
      _log.info('Keine zeitgesteuerte Sicherung (PAPERBUDDY_BACKUP_DIR und PAPERBUDDY_BACKUP_PASSPHRASE setzen).');
    }
    if (config.mailInterval > Duration.zero) mail.start();
    // Wie Paperless-ngx: das lernende Matching stündlich nachtrainieren.
    consumer.classifier.trainIfNeeded();
    _trainTimer = Timer.periodic(const Duration(hours: 1), (_) => consumer.classifier.trainIfNeeded());

    final handler = const Pipeline()
        .addMiddleware(logRequests(logger: (msg, isError) => isError ? _log.severe(msg) : _log.fine(msg)))
        .addHandler(this.handler);
    _http = await bind(handler, config.host, config.port);
    _log.info('PaperBuddy $paperbuddyVersion läuft auf http://${config.host}:${config.port}');
  }

  Future<void> close() async {
    watcher?.stop();
    trash.stop();
    workflows.stop();
    reminders.stop();
    backups.stop();
    accessLog.stop();
    mail.stop();
    scanners.close();
    _trainTimer?.cancel();
    await _http?.close();
    db.close();
  }
}

/// Startet den HTTP-Server ohne Angaben zur Technik: kein `X-Powered-By`
/// und kein veraltetes `X-XSS-Protection` aus den Vorgaben von `dart:io`.
Future<HttpServer> bind(Handler handler, Object address, int port) async {
  final http = await io.serve(handler, address, port, poweredByHeader: null);
  http.autoCompress = true;
  http.defaultResponseHeaders
    ..removeAll('x-xss-protection')
    ..removeAll('x-frame-options');
  return http;
}

/// Speicher nach `STORAGE_BACKEND`; entfernte Speicher werden beim Start geprüft.
Future<BlobStore> createStore(Config config) async {
  final s = config.storage;
  final cache = p.join(config.dataDir, 'cache');
  String need(String? v, String name) =>
      (v == null || v.isEmpty) ? throw StateError('PAPERBUDDY_$name fehlt für STORAGE_BACKEND=${s.backend}') : v;
  switch (s.backend) {
    case 's3':
      final store = S3BlobStore(
        endpoint: Uri.parse(need(s.s3Endpoint, 'S3_ENDPOINT')),
        bucket: need(s.s3Bucket, 'S3_BUCKET'),
        region: s.s3Region,
        accessKey: need(s.s3AccessKey, 'S3_ACCESS_KEY'),
        secretKey: need(s.s3SecretKey, 'S3_SECRET_KEY'),
        prefix: s.s3Prefix,
        pathStyle: s.s3PathStyle,
        cacheDir: cache,
        maxCacheBytes: s.cacheMb * 1024 * 1024,
      );
      await store.check();
      return store;
    case 'webdav':
      final store = WebDavBlobStore(
        baseUrl: Uri.parse(need(s.webdavUrl, 'WEBDAV_URL')),
        username: need(s.webdavUser, 'WEBDAV_USER'),
        password: need(s.webdavPassword, 'WEBDAV_PASSWORD'),
        cacheDir: cache,
        maxCacheBytes: s.cacheMb * 1024 * 1024,
      );
      await store.check();
      return store;
    case 'local':
      return LocalBlobStore(config.mediaDir);
  }
  throw StateError('Unbekanntes STORAGE_BACKEND: ${s.backend} (local, s3, webdav)');
}
