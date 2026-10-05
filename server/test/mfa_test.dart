import 'dart:convert';

import 'package:paperbuddy_server/src/totp.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.close());

  test('TOTP nach RFC 6238 (Testvektor)', () {
    // RFC 6238, Anhang B: Schlüssel "12345678901234567890", SHA-1, T = 59 s.
    final secret = Totp.base32Encode(utf8.encode('12345678901234567890') as dynamic);
    expect(Totp.codeAt(secret, 59 ~/ 30), '287082');
    expect(Totp.codeAt(secret, 1111111109 ~/ 30), '081804');
    expect(Totp.base32Decode(secret), utf8.encode('12345678901234567890'));
  });

  Future<dynamic> login(String user, String password, [String? code]) async {
    final r = await env.call('POST', '/api/token/', as: 'niemand', body: {
      'username': user,
      'password': password,
      'code': ?code,
    });
    return (r.statusCode, jsonDecode(await r.readAsString()));
  }

  test('Einrichten, Anmelden mit Code, Wiederherstellungscode, Abschalten', () async {
    final setup = await env.json('GET', '/api/profile/totp/');
    final secret = setup['secret'] as String;
    expect(setup['url'], startsWith('otpauth://totp/PaperBuddy:admin?secret=$secret'));
    expect(setup['qr_svg'], startsWith('<svg'));

    // Falscher Code schaltet nichts ein.
    await env.json('POST', '/api/profile/totp/', body: {'secret': secret, 'code': '000000'}, status: 400);
    expect((await env.json('GET', '/api/profile/'))['is_mfa_enabled'], isFalse);

    final step = Totp.stepAt(DateTime.now());
    final activated = await env.json('POST', '/api/profile/totp/', body: {
      'secret': secret,
      'code': Totp.codeAt(secret, step),
    });
    final recovery = (activated['recovery_codes'] as List).cast<String>();
    expect(recovery, hasLength(10));
    expect((await env.json('GET', '/api/profile/'))['is_mfa_enabled'], isTrue);
    final users = await env.json('GET', '/api/users/');
    expect(users['results'].first['is_mfa_enabled'], isTrue);

    // Ohne Code: wie Paperless-ngx, damit Apps das Code-Feld zeigen.
    var (status, body) = await login('admin', 'geheim123');
    expect(status, 400);
    expect(body['non_field_errors'], ['MFA code is required']);

    // Derselbe Code wie beim Einschalten gilt kein zweites Mal.
    (status, body) = await login('admin', 'geheim123', Totp.codeAt(secret, step));
    expect(body['non_field_errors'], ['Invalid MFA code']);

    (status, body) = await login('admin', 'geheim123', Totp.codeAt(secret, step + 1));
    expect(status, 200);
    expect(body['token'], env.tokens['admin']);

    // Wiederherstellungscode: einmal gültig, auch mit Großbuchstaben.
    (status, _) = await login('admin', 'geheim123', recovery.first.toUpperCase());
    expect(status, 200);
    (status, _) = await login('admin', 'geheim123', recovery.first);
    expect(status, 400);

    // Basic-Auth kennt keinen zweiten Faktor und ist darum gesperrt.
    final basic = await env.call('GET', '/api/profile/', as: 'niemand', headers: {
      'authorization': 'Basic ${base64.encode(utf8.encode('admin:geheim123'))}',
    });
    expect(basic.statusCode, 401);

    await env.json('DELETE', '/api/profile/totp/');
    (status, _) = await login('admin', 'geheim123');
    expect(status, 200);
    await env.json('DELETE', '/api/profile/totp/', status: 404);
  });

  test('Nach fünf falschen Codes ist der zweite Faktor gesperrt', () async {
    final id = env.server.db.select("SELECT id FROM users WHERE username = 'admin'").first['id'] as int;
    final secret = Totp.newSecret();
    final now = DateTime.now();
    env.server.auth.enableTotp(id, secret, Totp.codeAt(secret, Totp.stepAt(now)));
    for (var i = 0; i < 5; i++) {
      var (status, body) = await login('admin', 'geheim123', '111111');
      expect(body['non_field_errors'], ['Invalid MFA code']);
    }
    final (_, body) = await login('admin', 'geheim123', Totp.codeAt(secret, Totp.stepAt(now) + 1));
    expect(body['non_field_errors'].first, startsWith('Too many'));
  });

  test('Administrator setzt die Zwei-Faktor-Anmeldung eines Benutzers zurück', () async {
    final id = env.addUser('bob');
    final secret = Totp.newSecret();
    env.server.auth.enableTotp(id, secret, Totp.codeAt(secret, Totp.stepAt(DateTime.now())));
    await env.json('POST', '/api/users/$id/deactivate_totp/', as: 'bob', status: 403);
    await env.json('POST', '/api/users/$id/deactivate_totp/');
    expect(env.server.auth.mfaEnabled(id), isFalse);
    final (status, _) = await login('bob', 'passwort123');
    expect(status, 200);
  });
}
