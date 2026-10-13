import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paperbuddy/src/app_state.dart';
import 'package:paperbuddy/src/l10n.dart';
import 'package:paperbuddy/src/session_store.dart';
import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart' as shelf;

/// Echter PaperBuddy-Server im Testprozess, ohne Netzwerk angesprochen.
class TestServer {
  TestServer._(this.dir, this.server);

  final Directory dir;
  final PaperbuddyServer server;

  static const address = 'http://paperbuddy.test';
  static const username = 'admin';
  static const password = 'geheim123';

  /// [ai]: lokale KI mit einem Wortmodell statt ONNX.
  static Future<TestServer> start({bool ai = false}) async {
    final dir = await Directory.systemTemp.createTemp('paperbuddy-app-test-');
    final db = openInMemoryDatabase();
    final server = await PaperbuddyServer.create(
      Config.fromEnvironment({
        'PAPERBUDDY_DATA_DIR': dir.path,
        'PAPERBUDDY_ADMIN_USER': username,
        'PAPERBUDDY_ADMIN_PASSWORD': password,
      }),
      database: db,
      ai: ai ? AiService.withEmbedder(db, _WordEmbedder()) : null,
    );
    return TestServer._(dir, server);
  }

  /// HTTP-Client, der Anfragen direkt an den Server-Handler gibt.
  http.Client client() => MockClient.streaming((request, body) async {
    final response = await server.handler(
      shelf.Request(
        request.method,
        request.url,
        headers: request.headers,
        body: body,
      ),
    );
    return http.StreamedResponse(
      response.read(),
      response.statusCode,
      headers: response.headers,
      contentLength: response.contentLength,
    );
  });

  Future<void> stop() async {
    await server.ai.close();
    server.db.close();
    await dir.delete(recursive: true);
  }
}

Future<AppState> newAppState(TestServer server) async {
  // Die Tests lesen deutsche Texte, auch auf einem englischen Testrechner.
  deviceLanguage = () => 'de';
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  return AppState(
    SessionStore(await SharedPreferences.getInstance()),
    httpClient: server.client,
  );
}

/// Ein Modell für Tests: jedes Wort ein fester Zufallsvektor, ein Text die
/// normierte Summe. Texte mit gemeinsamen Wörtern liegen nah beieinander.
class _WordEmbedder implements TextEmbedder {
  @override
  String get model => 'test';
  @override
  int get dimensions => 32;

  Float32List _vector(String text) {
    final v = Float32List(dimensions);
    for (final m in RegExp(r'\p{L}{3,}', unicode: true).allMatches(text.toLowerCase())) {
      final r = Random(m.group(0)!.hashCode);
      for (var i = 0; i < dimensions; i++) {
        v[i] += r.nextDouble() * 2 - 1;
      }
    }
    return normalize(v);
  }

  @override
  Future<Float32List> query(String text) async => _vector(text);

  @override
  Future<List<Passage>> passages(String title, String content) async =>
      [Passage(_vector('$title $content'), 0, content.length)];

  @override
  Future<void> close() async {}
}
