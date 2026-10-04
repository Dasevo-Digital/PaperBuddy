import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:sqlite3/sqlite3.dart';

import 'api/paperless_api.dart';
import 'auth.dart';
import 'config.dart';
import 'db.dart';
import 'processing/consume_folder.dart';
import 'processing/consumer.dart';
import 'processing/tools.dart';
import 'storage.dart';

final _log = Logger('server');

/// Setzt alle Teile zusammen; auch von den Tests genutzt.
class PaperbuddyServer {
  PaperbuddyServer._(
    this.config,
    this.db,
    this.auth,
    this.consumer,
    this.handler,
    this.watcher,
  );

  final Config config;
  final Database db;
  final AuthService auth;
  final Consumer consumer;
  final Handler handler;
  final ConsumeFolderWatcher? watcher;
  HttpServer? _http;

  static Future<PaperbuddyServer> create(
    Config config, {
    Database? database,
  }) async {
    final db = database ?? openDatabase(config.databasePath);
    final auth = AuthService(db);
    if (!auth.hasUsers &&
        config.adminUser != null &&
        config.adminPassword != null) {
      auth.createUser(
        config.adminUser!,
        config.adminPassword!,
        superuser: true,
      );
      _log.info('Administrator "${config.adminUser}" angelegt');
    }
    final tools = ExternalTools(ocrLanguage: config.ocrLanguage);
    final store = LocalBlobStore(config.mediaDir);
    final consumer = Consumer(
      db: db,
      store: store,
      tools: tools,
      workDir: p.join(config.dataDir, 'work'),
    );
    final api = PaperlessApi(
      db: db,
      auth: auth,
      store: store,
      consumer: consumer,
      tools: tools,
      corsOrigins: config.corsOrigins,
    );
    final watcher = config.consumeDir == null
        ? null
        : ConsumeFolderWatcher(
            config.consumeDir!,
            consumer,
            interval: config.consumePollInterval,
          );
    return PaperbuddyServer._(config, db, auth, consumer, api.handler, watcher);
  }

  Future<void> serve() async {
    final missing = (await ExternalTools(
      ocrLanguage: config.ocrLanguage,
    ).report()).entries.where((e) => !e.value).map((e) => e.key);
    if (missing.isNotEmpty) {
      _log.warning(
        'Nicht gefunden: ${missing.join(', ')}. '
        'OCR und Vorschaubilder sind eingeschränkt.',
      );
    }
    if (!auth.hasUsers) {
      _log.warning(
        'Noch kein Benutzer vorhanden. PAPERBUDDY_ADMIN_USER und '
        'PAPERBUDDY_ADMIN_PASSWORD setzen oder `dart run bin/manage.dart '
        'createsuperuser` ausführen.',
      );
    }
    watcher?.start();
    final handler = const Pipeline()
        .addMiddleware(
          logRequests(
            logger: (msg, isError) =>
                isError ? _log.severe(msg) : _log.fine(msg),
          ),
        )
        .addHandler(this.handler);
    _http = await io.serve(handler, config.host, config.port);
    _http!.autoCompress = true;
    _log.info('paperbuddy läuft auf http://${config.host}:${config.port}');
  }

  Future<void> close() async {
    watcher?.stop();
    await _http?.close();
    db.close();
  }
}
