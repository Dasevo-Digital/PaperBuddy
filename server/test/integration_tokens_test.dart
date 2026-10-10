import 'dart:convert';

import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.close());

  test('Famio-Abruf: nur Dokumente mit dem Tag, alle Fristen daran, nur lesen', () async {
    final family = (await env.json('POST', '/api/tags/', status: 201, body: {'name': 'Familie', 'matching_algorithm': 0}))['id'];
    final shared = (await env.uploadText('pass.txt', 'Reisepass Kind', fields: {'tags': family}))!;
    final private = (await env.uploadText('gehalt.txt', 'Gehaltsabrechnung'))!;
    env.server.db.execute('UPDATE documents SET owner = NULL');
    env.addUser('bob', permissions: ['view_document']);
    await env.json('POST', '/api/reminders/', status: 201, body: {'document': shared, 'due': '2027-03-01', 'note': 'Pass verlängern'});
    await env.json('POST', '/api/reminders/', as: 'bob', status: 201, body: {'document': shared, 'due': '2027-04-01', 'note': 'Foto machen'});
    await env.json('POST', '/api/reminders/', status: 201, body: {'document': private, 'due': '2027-01-01', 'note': 'Privat'});

    final created = await env.json('POST', '/api/integration_tokens/', status: 201, body: {'name': 'Famio', 'tag': family});
    final token = created['token'] as String;
    expect(token, startsWith('pbi_'));
    expect(created['tag_name'], 'Familie');
    expect(env.server.db.select('SELECT key_hash FROM integration_tokens').first['key_hash'], isNot(token));
    expect((await env.json('GET', '/api/integration_tokens/') as List).single.containsKey('token'), isFalse);

    Future<(int, dynamic)> famio(String method, String path, {Object? body}) async {
      final r = await env.call(method, path, as: '', body: body, headers: {'authorization': 'Token $token'});
      final text = await r.readAsString();
      return (r.statusCode, text.isEmpty || !text.trimLeft().startsWith(RegExp(r'[\[{]')) ? text : jsonDecode(text));
    }

    // So fragt Famio ab (documents/paperbuddy.dart).
    final (_, tags) = await famio('GET', '/api/tags/?name__iexact=familie&page_size=100');
    expect([for (final t in tags['results']) t['name']], ['Familie']);
    final (_, docs) = await famio('GET', '/api/documents/?tags__id__all=$family&page_size=100');
    expect([for (final d in docs['results']) d['id']], [shared]);
    final (_, all) = await famio('GET', '/api/documents/');
    expect(all['count'], 1, reason: 'Dokumente ohne den Tag bleiben unsichtbar');
    expect((await famio('GET', '/api/documents/$private/')).$1, 404);
    expect((await famio('GET', '/api/documents/$shared/download/')).$1, 200);
    final (_, reminders) = await famio('GET', '/api/reminders/?done=false');
    expect([for (final r in reminders['results']) r['note']], ['Pass verlängern', 'Foto machen']);

    // Nur lesen, nur die freigegebenen Bereiche.
    for (final (method, path) in [
      ('PATCH', '/api/documents/$shared/'),
      ('POST', '/api/reminders/'),
      ('GET', '/api/users/'),
      ('GET', '/api/documents/$shared/access_log/'),
      ('GET', '/api/integration_tokens/'),
      ('GET', '/api/statistics/'),
    ]) {
      expect((await famio(method, path, body: method == 'GET' ? null : {'title': 'x'})).$1, 403, reason: '$method $path');
    }
    expect((await famio('GET', '/metrics')).$1, 401);

    await env.json('DELETE', '/api/integration_tokens/${created['id']}/', status: 204);
    expect((await famio('GET', '/api/documents/')).$1, 401);
  });

  test('ein Token sieht höchstens, was sein Ersteller sieht', () async {
    final family = (await env.json('POST', '/api/tags/', status: 201, body: {'name': 'Familie', 'matching_algorithm': 0}))['id'];
    final adminsOnly = (await env.uploadText('a.txt', 'Nur für den Admin', fields: {'tags': family}))!;
    final bobs = (await env.uploadText('b.txt', 'Für Bob', fields: {'tags': family}))!;
    final bob = env.addUser('bob', permissions: ['view_document', 'view_tag']);
    final admin = env.server.db.select("SELECT id FROM users WHERE username = 'admin'").first['id'];
    env.server.db.execute('UPDATE documents SET owner = ? WHERE id = ?', [admin, adminsOnly]);
    env.server.db.execute('UPDATE documents SET owner = ? WHERE id = ?', [bob, bobs]);
    // Ein gemeinsamer Tag ohne Eigentümer; einen fremden dürfte Bob nicht nutzen.
    env.server.db.execute('UPDATE tags SET owner = NULL');

    final created = await env.json('POST', '/api/integration_tokens/', as: 'bob', status: 201, body: {'name': 'Famio', 'tag': family});
    final r = await env.call('GET', '/api/documents/', as: '', headers: {'authorization': 'Token ${created['token']}'});
    final ids = [for (final d in jsonDecode(await r.readAsString())['results']) d['id']];
    expect(ids, [bobs]);
    // Fremde Token kann Bob weder sehen noch löschen.
    final mine = await env.json('POST', '/api/integration_tokens/', status: 201, body: {'name': 'Admin', 'tag': family});
    expect((await env.json('GET', '/api/integration_tokens/', as: 'bob') as List).map((t) => t['name']), ['Famio']);
    await env.json('DELETE', '/api/integration_tokens/${mine['id']}/', as: 'bob', status: 404);
    await env.json('POST', '/api/integration_tokens/', status: 400, body: {'name': '', 'tag': 999});
  });
}
