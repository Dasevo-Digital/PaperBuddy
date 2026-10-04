import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:sqlite3/sqlite3.dart';

import 'access.dart';
import 'api/custom_fields.dart';
import 'api/paperless_api.dart';
import 'auth.dart';
import 'config.dart';
import 'db.dart';
import 'processing/consume_folder.dart';
import 'processing/consumer.dart';
import 'processing/tools.dart';
import 'mail/mail_service.dart';
import 'scanners/escl.dart';
import 'storage.dart';
import 'trash.dart';
import 'workflows.dart';

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
  final ScannerService scanners;
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
    store ??= LocalBlobStore(config.mediaDir);
    final consumer = Consumer(db: db, store: store, tools: tools, workDir: p.join(config.dataDir, 'work'));
    final trash = Trash(db, store, access, delay: config.emptyTrashDelay);
    final customFields = CustomFieldsResource(db, access);
    final workflows = WorkflowEngine(
      db: db,
      access: access,
      store: store,
      customFields: customFields,
      email: config.email,
      publicUrl: config.publicUrl,
    );
    consumer.hooks = workflows;
    final mail = MailService(
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
    final api = PaperlessApi(
      db: db,
      auth: auth,
      access: access,
      store: store,
      consumer: consumer,
      tools: tools,
      trash: trash,
      customFields: customFields,
      extraRoutes: [workflows.mount, mail.mount, scanners.mount],
      onDocumentUpdated: workflows.documentUpdated,
      corsOrigins: config.corsOrigins,
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
    if (config.mailInterval > Duration.zero) mail.start();
    // Wie Paperless-ngx: das lernende Matching stündlich nachtrainieren.
    consumer.classifier.trainIfNeeded();
    _trainTimer = Timer.periodic(const Duration(hours: 1), (_) => consumer.classifier.trainIfNeeded());

    final handler = const Pipeline()
        .addMiddleware(logRequests(logger: (msg, isError) => isError ? _log.severe(msg) : _log.fine(msg)))
        .addHandler(this.handler);
    _http = await io.serve(handler, config.host, config.port);
    _http!.autoCompress = true;
    _log.info('PaperBuddy läuft auf http://${config.host}:${config.port}');
  }

  Future<void> close() async {
    watcher?.stop();
    trash.stop();
    workflows.stop();
    mail.stop();
    scanners.close();
    _trainTimer?.cancel();
    await _http?.close();
    db.close();
  }
}
