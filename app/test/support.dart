import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paperbuddy/src/app_state.dart';
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

  static Future<TestServer> start() async {
    final dir = await Directory.systemTemp.createTemp('paperbuddy-app-test-');
    final server = await PaperbuddyServer.create(
      Config.fromEnvironment({
        'PAPERBUDDY_DATA_DIR': dir.path,
        'PAPERBUDDY_ADMIN_USER': username,
        'PAPERBUDDY_ADMIN_PASSWORD': password,
      }),
      database: openInMemoryDatabase(),
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
    server.db.close();
    await dir.delete(recursive: true);
  }
}

Future<AppState> newAppState(TestServer server) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  return AppState(
    SessionStore(await SharedPreferences.getInstance()),
    httpClient: server.client,
  );
}
