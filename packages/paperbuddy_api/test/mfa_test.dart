import 'dart:io';

import 'package:paperbuddy_api/paperbuddy_api.dart';
import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:paperbuddy_server/src/totp.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// Zwei-Faktor-Anmeldung über den Client gegen den echten Server.
void main() {
  late Directory tmp;
  late PaperbuddyServer server;
  late HttpServer http;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('paperbuddy-mfa-test-');
    server = await PaperbuddyServer.create(
      Config.fromEnvironment({
        'PAPERBUDDY_DATA_DIR': tmp.path,
        'PAPERBUDDY_ADMIN_USER': 'admin',
        'PAPERBUDDY_ADMIN_PASSWORD': 'geheim123',
      }),
      database: openInMemoryDatabase(),
    );
    http = await io.serve(server.handler, 'localhost', 0);
  });

  tearDown(() async {
    await http.close(force: true);
    server.workflows.stop();
    server.db.close();
    await tmp.delete(recursive: true);
  });

  test('TOTP einrichten, mit Code anmelden, Benutzer zurücksetzen', () async {
    final address = 'localhost:${http.port}';
    final admin = await PaperlessClient.login(address, 'admin', 'geheim123');
    final setup = await admin.totpSetup();
    expect(setup.url, startsWith('otpauth://totp/PaperBuddy:admin?'));
    final step = Totp.stepAt(DateTime.now());
    final codes = await admin.activateTotp(setup.secret, Totp.codeAt(setup.secret, step));
    expect(codes, hasLength(10));
    expect((await admin.profile()).isMfaEnabled, isTrue);

    await expectLater(
      PaperlessClient.login(address, 'admin', 'geheim123'),
      throwsA(isA<MfaRequiredException>().having((e) => e.invalid, 'invalid', isFalse)),
    );
    await expectLater(
      PaperlessClient.login(address, 'admin', 'geheim123', code: '000000'),
      throwsA(isA<MfaRequiredException>().having((e) => e.invalid, 'invalid', isTrue)),
    );
    final again = await PaperlessClient.login(address, 'admin', 'geheim123',
        code: Totp.codeAt(setup.secret, step + 1));
    expect(again.user.username, 'admin');

    final bob = await admin.createUser({'username': 'bob', 'password': 'passwort123'});
    final bobId = bob.id;
    final bobSecret = Totp.newSecret();
    server.auth.enableTotp(bobId, bobSecret, Totp.codeAt(bobSecret, step));
    expect((await admin.users()).firstWhere((u) => u.id == bobId).isMfaEnabled, isTrue);
    await admin.deactivateUserTotp(bobId);
    expect((await admin.users()).firstWhere((u) => u.id == bobId).isMfaEnabled, isFalse);

    await admin.deactivateTotp();
    expect((await admin.profile()).isMfaEnabled, isFalse);
    admin.close();
    again.close();
  });
}
