import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.close());

  List<String> actions(List<dynamic> entries) => [for (final e in entries) e['action'] as String];

  test('angesehen, heruntergeladen, per Freigabelink; Wiederholungen zählen einmal', () async {
    final id = await env.uploadText('vertrag.txt', 'Mietvertrag Wohnung');
    await env.json('GET', '/api/documents/$id/');
    await env.json('GET', '/api/documents/$id/');
    await env.call('GET', '/api/documents/$id/preview/');
    await env.call('GET', '/api/documents/$id/download/');

    final link = await env.json('POST', '/api/share_links/', status: 201, body: {'document': id, 'file_version': 'original'});
    final shared = await env.call('GET', '/share/${link['slug']}/', as: '');
    expect(shared.statusCode, 200);

    final log = await env.json('GET', '/api/documents/$id/access_log/') as List;
    expect(actions(log), ['share', 'download', 'view']);
    expect(log.last['actor']['username'], 'admin');
    expect(log.last['address'], isNull, reason: 'bei Angemeldeten keine Adresse');
    expect(log.first['actor'], isNull);
    expect(log.first['share_link'], link['id']);
    expect(log.first['address'], isNotNull);

    // Der Paperless-Verlauf bleibt unverändert.
    final history = await env.json('GET', '/api/documents/$id/history/') as List;
    expect(history.map((h) => h['action']), everyElement(isIn(['create', 'update'])));
  });

  test('nur Eigentümer, Administratoren oder mit Recht auf den Verlauf', () async {
    final id = await env.uploadText('privat.txt', 'Kontoauszug');
    env.addUser('bob', permissions: ['view_document']);
    env.server.db.execute("UPDATE documents SET owner = (SELECT id FROM users WHERE username = 'admin')");
    await env.json('PATCH', '/api/documents/$id/', body: {
      'set_permissions': {
        'view': {'users': [env.server.db.select("SELECT id FROM users WHERE username = 'bob'").first['id']], 'groups': []},
        'change': {'users': [], 'groups': []},
      },
    });
    await env.json('GET', '/api/documents/$id/', as: 'bob');
    await env.json('GET', '/api/documents/$id/access_log/', as: 'bob', status: 403);
    final log = await env.json('GET', '/api/documents/$id/access_log/') as List;
    expect(log.map((e) => e['actor']['username']), contains('bob'));
  });

  test('abschaltbar und mit Aufbewahrungsfrist', () async {
    final off = await TestEnv.create(env: {'PAPERBUDDY_ACCESS_LOG': 'false'});
    addTearDown(off.close);
    final id = await off.uploadText('a.txt', 'Inhalt');
    await off.json('GET', '/api/documents/$id/');
    expect(await off.json('GET', '/api/documents/$id/access_log/'), isEmpty);

    final doc = await env.uploadText('b.txt', 'Inhalt');
    final log = env.server.accessLog;
    final now = DateTime.now();
    log.record(doc!, 'download', userId: 1, now: now.subtract(const Duration(days: 100)));
    log.record(doc, 'download', userId: 1, now: now.subtract(const Duration(days: 5)));
    // Nach dem Wiederholungsfenster zählt ein Zugriff erneut.
    log.record(doc, 'download', userId: 1, now: now.subtract(const Duration(days: 5, minutes: -11)));
    expect(log.entries(doc), hasLength(3));
    expect(log.prune(now: now), 1);
    expect(log.entries(doc), hasLength(2));
  });
}
