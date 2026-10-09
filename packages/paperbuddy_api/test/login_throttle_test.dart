import 'dart:io';

import 'package:paperbuddy_api/paperbuddy_api.dart';
import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:test/test.dart';

/// Login-Bremse des Servers aus Sicht des Clients.
void main() {
  late Directory tmp;
  late PaperbuddyServer server;
  late HttpServer http;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('paperbuddy-throttle-test-');
    server = await PaperbuddyServer.create(
      Config.fromEnvironment({
        'PAPERBUDDY_DATA_DIR': tmp.path,
        'PAPERBUDDY_ADMIN_USER': 'admin',
        'PAPERBUDDY_ADMIN_PASSWORD': 'geheim123',
      }),
      database: openInMemoryDatabase(),
    );
    http = await bind(server.handler, InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await http.close(force: true);
    server.workflows.stop();
    server.db.close();
    await tmp.delete(recursive: true);
  });

  test('nach fünf falschen Passwörtern eine deutsche Meldung mit Wartezeit', () async {
    final address = '127.0.0.1:${http.port}';
    for (var i = 0; i < 5; i++) {
      await expectLater(
        PaperlessClient.login(address, 'admin', 'falsch'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
      );
    }
    await expectLater(
      PaperlessClient.login(address, 'admin', 'geheim123'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'status', 429)
            .having((e) => e.message, 'message', 'Zu viele Fehlversuche. Bitte in 30 Sekunden erneut versuchen.'),
      ),
    );
  });
}
