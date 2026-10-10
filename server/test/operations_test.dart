import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Gespeicherte API-Beschreibung; neu schreiben mit
/// `UPDATE_OPENAPI=1 dart test test/operations_test.dart`.
final _openApiFile = File('../docs/openapi.json');

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.close());

  test('Zustand: ohne Anmeldung knapp, für Administratoren mit Prüfungen', () async {
    final public = await env.json('GET', '/api/health/', as: '');
    expect(public, {'status': 'ok', 'version': paperbuddyVersion});

    env.addUser('bob', permissions: ['view_document']);
    expect((await env.json('GET', '/api/health/', as: 'bob')).containsKey('checks'), isFalse);

    final admin = await env.json('GET', '/api/health/');
    expect(admin['checks']['database'], 'ok');
    expect(admin['checks']['backup'], {'status': 'off'});
    expect(admin['checks']['queue'], isA<Map<String, dynamic>>());
  });

  test('Zustand: fehlgeschlagene Sicherung meldet degraded', () async {
    final e = await TestEnv.create(env: {
      'PAPERBUDDY_BACKUP_DIR': '${env.dir.path}/sicherungen',
      'PAPERBUDDY_BACKUP_PASSPHRASE': 'lange-passphrase',
    });
    addTearDown(e.close);
    expect((await e.json('GET', '/api/health/'))['status'], 'ok', reason: 'noch kein Lauf fällig');
    File('${e.dir.path}/backup-status.json').writeAsStringSync(jsonEncode({
      'ok': false,
      'problems': ['Festplatte voll'],
      'started': DateTime.now().toIso8601String(),
    }));
    final health = await e.json('GET', '/api/health/');
    expect(health['status'], 'degraded');
    expect(health['checks']['backup']['status'], 'failed');
    expect(health['checks']['backup']['problems'], ['Festplatte voll']);
  });

  test('Metriken nur für Administratoren, im Prometheus-Format', () async {
    expect((await env.call('GET', '/metrics', as: '')).statusCode, 401);
    env.addUser('bob', permissions: ['view_document']);
    expect((await env.call('GET', '/metrics', as: 'bob')).statusCode, 401);

    await env.uploadText('rechnung.txt', 'Stromrechnung');
    await env.call('POST', '/api/token/', as: '', body: {'username': 'admin', 'password': 'falsch'});
    final r = await env.call('GET', '/metrics');
    expect(r.statusCode, 200);
    expect(r.headers['content-type'], startsWith('text/plain; version=0.0.4'));
    final text = await r.readAsString();
    expect(text, contains('paperbuddy_info{version="$paperbuddyVersion",paperless_api="2.18.0"} 1'));
    expect(text, contains('paperbuddy_documents{state="active"} 1'));
    expect(text, contains('paperbuddy_login_failures_total 1'));
    expect(text, contains('paperbuddy_http_requests_total{method="POST",code="4xx"} 1'));
    expect(text, contains('paperbuddy_backup_enabled 0'));
    expect(text, contains('# TYPE paperbuddy_tasks gauge'));
  });

  test('API-Beschreibung aus den Routen, Erweiterungen markiert', () async {
    expect((await env.call('GET', '/api/schema/', as: '')).statusCode, 401);
    final schema = await env.json('GET', '/api/schema/') as Map<String, dynamic>;
    expect(schema['openapi'], '3.1.0');
    final paths = schema['paths'] as Map<String, dynamic>;
    expect((paths['/api/documents/{id}/'] as Map).keys, containsAll(['get', 'patch', 'put', 'delete']));
    expect(paths['/api/documents/{id}/']['get']['parameters'][0]['schema'], {'type': 'integer'});
    expect(paths['/api/reminders/']['x-paperbuddy-extension'], isTrue);
    expect(paths['/api/documents/'].containsKey('x-paperbuddy-extension'), isFalse);
    expect(paths['/api/token/']['post']['security'], isEmpty);

    // Gespeicherte Fassung muss zum Code passen (ohne Versionsnummer).
    String normalized(Map<String, dynamic> s) =>
        const JsonEncoder.withIndent('  ').convert({...s, 'info': {...s['info'] as Map, 'version': 'x'}});
    if (Platform.environment['UPDATE_OPENAPI'] == '1') {
      _openApiFile.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(schema)}\n');
    }
    final saved = jsonDecode(_openApiFile.readAsStringSync()) as Map<String, dynamic>;
    expect(normalized(saved), normalized(schema), reason: 'docs/openapi.json veraltet: UPDATE_OPENAPI=1 dart test test/operations_test.dart');
  });
}
