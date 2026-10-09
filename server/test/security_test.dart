import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'helpers.dart';

class _Connection implements HttpConnectionInfo {
  _Connection(String address) : remoteAddress = InternetAddress(address);
  @override
  final InternetAddress remoteAddress;
  @override
  int get remotePort => 40000;
  @override
  int get localPort => 8000;
}

Request _from(String peer, {Map<String, String> headers = const {}}) => Request(
  'GET',
  Uri.parse('http://localhost/api/'),
  headers: headers,
  context: {'shelf.io.connection_info': _Connection(peer)},
);

void main() {
  group('LoginThrottle', () {
    late DateTime now;
    late LoginThrottle throttle;
    setUp(() {
      now = DateTime(2026, 10, 9, 12);
      throttle = LoginThrottle(clock: () => now);
    });

    test('sperrt nach fünf Fehlern, Wartezeit verdoppelt sich', () {
      for (var i = 0; i < 4; i++) {
        throttle.failed('1.2.3.4', 'anna');
      }
      expect(throttle.blockedFor('1.2.3.4', 'anna'), isNull);
      throttle.failed('1.2.3.4', 'anna');
      expect(throttle.blockedFor('1.2.3.4', 'Anna '), const Duration(seconds: 30));
      // Andere Adresse, anderes Konto: frei.
      expect(throttle.blockedFor('5.6.7.8', 'anna'), isNull);
      expect(throttle.blockedFor('1.2.3.4', 'bob'), isNull);

      now = now.add(const Duration(seconds: 31));
      expect(throttle.blockedFor('1.2.3.4', 'anna'), isNull);
      throttle.failed('1.2.3.4', 'anna');
      expect(throttle.blockedFor('1.2.3.4', 'anna'), const Duration(seconds: 60));

      // Nach einer Stunde ohne Fehler ist alles vergessen.
      now = now.add(const Duration(hours: 2));
      throttle.failed('1.2.3.4', 'anna');
      expect(throttle.blockedFor('1.2.3.4', 'anna'), isNull);
    });

    test('viele Konten von einer Adresse und ein Konto von vielen Adressen', () {
      for (var i = 0; i < 20; i++) {
        throttle.failed('1.2.3.4', 'user$i');
      }
      expect(throttle.blockedFor('1.2.3.4', 'neu'), isNotNull);

      for (var i = 0; i < 20; i++) {
        throttle.failed('10.0.0.$i', 'carla');
      }
      expect(throttle.blockedFor('10.0.0.99', 'carla'), isNotNull);
    });

    test('bekannte Adresse wird nicht vom Konto ausgesperrt', () {
      throttle.succeeded('192.168.1.5', 'anna');
      for (var i = 0; i < 20; i++) {
        throttle.failed('10.0.0.$i', 'anna');
      }
      expect(throttle.blockedFor('10.0.0.50', 'anna'), isNotNull);
      expect(throttle.blockedFor('192.168.1.5', 'anna'), isNull);
    });
  });

  group('ClientAddress', () {
    test('X-Forwarded-For nur von eingetragenen Proxys, letzter Eintrag zählt', () {
      const plain = ClientAddress();
      const proxied = ClientAddress(trustedProxies: ['172.18.0.1']);
      final spoofed = {'x-forwarded-for': '9.9.9.9'};
      expect(plain.of(_from('1.2.3.4', headers: spoofed)), '1.2.3.4');
      expect(proxied.of(_from('1.2.3.4', headers: spoofed)), '1.2.3.4');
      expect(proxied.of(_from('172.18.0.1', headers: {'x-forwarded-for': '9.9.9.9, 5.6.7.8'})), '5.6.7.8');
      expect(proxied.of(_from('172.18.0.1')), '172.18.0.1');
    });
  });

  group('API', () {
    late TestEnv env;
    setUp(() async => env = await TestEnv.create());
    tearDown(() => env.close());

    Future<Response> token(String password) => env.call(
      'POST',
      '/api/token/',
      as: '',
      body: {'username': 'admin', 'password': password},
    );

    test('Token-Anmeldung wird nach Fehlversuchen gedrosselt', () async {
      var now = DateTime.now();
      env.server.auth.throttle = LoginThrottle(clock: () => now);
      for (var i = 0; i < 5; i++) {
        expect((await token('falsch')).statusCode, 400);
      }
      // Auch das richtige Passwort wartet.
      final blocked = await token('geheim123');
      expect(blocked.statusCode, 429);
      expect(blocked.headers['retry-after'], '30');
      expect(jsonDecode(await blocked.readAsString())['detail'], contains('throttled'));

      now = now.add(const Duration(seconds: 31));
      final ok = await token('geheim123');
      expect(ok.statusCode, 200);
      expect(jsonDecode(await ok.readAsString())['token'], isNotEmpty);
    });

    test('Basic-Auth wird ebenso gedrosselt', () async {
      String basic(String pw) => 'Basic ${base64.encode(utf8.encode('admin:$pw'))}';
      Future<int> get(String pw) async =>
          (await env.call('GET', '/api/tags/', as: '', headers: {'authorization': basic(pw)})).statusCode;
      for (var i = 0; i < 5; i++) {
        expect(await get('falsch'), 401);
      }
      expect(await get('geheim123'), 429);
    });

    test('Sicherheits-Header an jeder Antwort', () async {
      for (final path in ['/api/', '/api/tags/', '/gibt-es-nicht', '/share/unbekannt/']) {
        final r = await env.call('GET', path);
        expect(r.headers['x-content-type-options'], 'nosniff', reason: path);
        expect(r.headers['x-frame-options'], 'DENY', reason: path);
        expect(r.headers['referrer-policy'], 'no-referrer', reason: path);
        expect(r.headers['content-security-policy'], contains("default-src 'none'"), reason: path);
        expect(r.headers.containsKey('strict-transport-security'), isFalse, reason: path);
      }
    });

    test('HSTS nur mit https-Adresse', () async {
      final https = await TestEnv.create(env: {'PAPERBUDDY_URL': 'https://docs.example.org'});
      addTearDown(https.close);
      final r = await https.call('GET', '/api/');
      expect(r.headers['strict-transport-security'], 'max-age=31536000');
    });

    test('keine Angaben zur Technik über HTTP', () async {
      final http = await bind(env.server.handler, InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      final client = HttpClient();
      addTearDown(client.close);
      final response = await (await client.get('127.0.0.1', http.port, '/api/')).close();
      await response.drain<void>();
      expect(response.headers.value('x-powered-by'), isNull);
      expect(response.headers.value('x-xss-protection'), isNull);
      expect(response.headers['x-frame-options'], ['DENY']);
      expect(response.headers.value('x-content-type-options'), 'nosniff');
    });
  });
}
