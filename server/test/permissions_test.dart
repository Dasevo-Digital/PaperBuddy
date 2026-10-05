import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  const docPerms = ['view_document', 'add_document', 'change_document', 'delete_document', 'view_tag', 'view_note', 'add_note'];

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.close());

  test('Ohne Modellrecht 403, mit Recht nur eigene und freigegebene Dokumente', () async {
    env.addUser('anna', permissions: docPerms);
    final bobId = env.addUser('bob', permissions: docPerms);
    env.addUser('nobody');

    await env.json('GET', '/api/documents/', as: 'nobody', status: 403);
    final annaDoc = (await env.uploadText('anna.txt', 'Annas Vertrag', as: 'anna'))!;
    final bobDoc = (await env.uploadText('bob.txt', 'Bobs Rechnung', as: 'bob'))!;
    final publicDoc = (await env.uploadText('alle.txt', 'Für alle'))!;
    env.server.db.execute('UPDATE documents SET owner = NULL WHERE id = ?', [publicDoc]);

    List ids(dynamic page) => (page['results'] as List).map((d) => d['id']).toList();
    expect(ids(await env.json('GET', '/api/documents/', as: 'anna')), unorderedEquals([annaDoc, publicDoc]));
    expect(ids(await env.json('GET', '/api/documents/')), unorderedEquals([annaDoc, bobDoc, publicDoc]));
    await env.json('GET', '/api/documents/$bobDoc/', as: 'anna', status: 404);

    // Bob gibt Anna Lesezugriff.
    await env.json('PATCH', '/api/documents/$bobDoc/', as: 'bob', body: {
      'set_permissions': {
        'view': {'users': [env.server.db.select("SELECT id FROM users WHERE username='anna'").first['id']], 'groups': []},
        'change': {'users': [], 'groups': []},
      },
    });
    final shared = await env.json('GET', '/api/documents/$bobDoc/?full_perms=true', as: 'anna');
    expect(shared['user_can_change'], isFalse);
    expect(shared['permissions']['view']['users'], hasLength(1));
    await env.json('PATCH', '/api/documents/$bobDoc/', as: 'anna', body: {'title': 'x'}, status: 403);
    final mine = await env.json('GET', '/api/documents/$bobDoc/', as: 'bob');
    expect(mine['is_shared_by_requester'], isTrue);
    expect((await env.json('GET', '/api/documents/?shared_by__id=$bobId'))['count'], 1);

    // Anna darf Eigentümer/Freigaben nicht ändern, auch mit Schreibrecht.
    final annaId = env.server.db.select("SELECT id FROM users WHERE username='anna'").first['id'];
    await env.json('PATCH', '/api/documents/$bobDoc/', as: 'bob', body: {
      'set_permissions': {
        'view': {'users': [], 'groups': []},
        'change': {'users': [annaId], 'groups': []},
      },
    });
    await env.json('PATCH', '/api/documents/$bobDoc/', as: 'anna', body: {'title': 'Von Anna', 'owner': annaId});
    final after = await env.json('GET', '/api/documents/$bobDoc/', as: 'bob');
    expect(after['title'], 'Von Anna');
    expect(after['owner'], bobId, reason: 'Eigentümer bleibt');

    // Bulk-Edit auf fremde, nicht freigegebene Dokumente scheitert.
    await env.json('POST', '/api/documents/bulk_edit/', as: 'bob',
        body: {'documents': [annaDoc], 'method': 'add_tag', 'parameters': {'tag': 1}}, status: 400);
  });

  test('Stammdaten mit Eigentümer und Zählung nur sichtbarer Dokumente', () async {
    env.addUser('anna', permissions: [...docPerms, 'add_tag', 'change_tag']);
    final tag = await env.json('POST', '/api/tags/', as: 'anna', body: {'name': 'Privat'}, status: 201);
    expect(tag['owner'], isNotNull);
    expect(tag['user_can_change'], isTrue);
    // Admin sieht den Tag, ein dritter Benutzer nicht.
    env.addUser('carl', permissions: ['view_tag']);
    expect((await env.json('GET', '/api/tags/', as: 'carl'))['count'], 0);
    await env.uploadText('t.txt', 'x', as: 'anna', fields: {'tags': tag['id']});
    expect((await env.json('GET', '/api/tags/${tag['id']}/'))['document_count'], 1);
    await env.json('POST', '/api/bulk_edit_objects/', as: 'anna', body: {
      'objects': [tag['id']],
      'object_type': 'tags',
      'operation': 'set_permissions',
      'permissions': {
        'view': {'users': [env.server.db.select("SELECT id FROM users WHERE username='carl'").first['id']], 'groups': []},
        'change': {'users': [], 'groups': []},
      },
    });
    final carlTags = await env.json('GET', '/api/tags/', as: 'carl');
    expect(carlTags['count'], 1);
    expect(carlTags['results'][0]['document_count'], 0, reason: 'Dokument ist für Carl nicht sichtbar');
  });

  test('Benutzer, Gruppen, geerbte Rechte, Profil und Token', () async {
    final group = await env.json('POST', '/api/groups/', body: {'name': 'Familie', 'permissions': ['view_document', 'view_tag']}, status: 201);
    await env.json('POST', '/api/groups/', body: {'name': 'X', 'permissions': ['fly_away']}, status: 400);
    final user = await env.json('POST', '/api/users/', body: {
      'username': 'emma',
      'password': 'sicher12345',
      'groups': [group['id']],
      'user_permissions': ['add_document'],
    }, status: 201);
    expect(user['inherited_permissions'], containsAll(['view_document', 'view_tag']));
    await env.json('POST', '/api/users/', body: {'username': 'emma'}, status: 400);

    final login = await env.json('POST', '/api/token/', body: {'username': 'emma', 'password': 'sicher12345'});
    env.tokens['emma'] = login['token'] as String;
    final ui = await env.json('GET', '/api/ui_settings/', as: 'emma');
    expect(ui['permissions'], containsAll(['view_document', 'add_document']));
    expect(ui['permissions'], isNot(contains('delete_document')));
    expect(ui['user']['groups'], [group['id']]);
    await env.json('GET', '/api/users/', as: 'emma', status: 403);

    // Nicht-Superuser darf niemanden zum Superuser machen.
    env.addUser('manager', permissions: ['add_user', 'change_user', 'view_user']);
    await env.json('POST', '/api/users/', as: 'manager', body: {'username': 'evil', 'is_superuser': true}, status: 403);

    await env.json('PATCH', '/api/profile/', as: 'emma', body: {'first_name': 'Emma', 'password': 'neuesPasswort1'});
    await env.json('POST', '/api/token/', body: {'username': 'emma', 'password': 'sicher12345'}, status: 400);
    await env.json('POST', '/api/token/', body: {'username': 'emma', 'password': 'neuesPasswort1'});
    final newToken = await env.json('POST', '/api/profile/generate_auth_token/', as: 'emma');
    expect(newToken, isNot(env.tokens['emma']));
    await env.json('GET', '/api/ui_settings/', as: 'emma', status: 401);

    // Deaktivieren sperrt aus; sich selbst löschen geht nicht.
    await env.json('PATCH', '/api/users/${user['id']}/', body: {'is_active': false});
    await env.json('POST', '/api/token/', body: {'username': 'emma', 'password': 'neuesPasswort1'}, status: 400);
    final me = env.server.db.select("SELECT id FROM users WHERE username='admin'").first['id'];
    await env.json('DELETE', '/api/users/$me/', status: 400);
    await env.json('DELETE', '/api/groups/${group['id']}/', status: 204);
  });

  test('Tasks sieht nur der Eigentümer', () async {
    env.addUser('anna', permissions: [...docPerms, 'view_paperlesstask']);
    await env.uploadText('a.txt', 'a', as: 'anna');
    await env.uploadText('b.txt', 'b');
    expect((await env.json('GET', '/api/tasks/', as: 'anna') as List), hasLength(1));
    final all = await env.json('GET', '/api/tasks/') as List;
    expect(all, hasLength(2));
    final detail = await env.json('GET', '/api/tasks/${all.first['id']}/');
    expect(detail['task_id'], all.first['task_id']);
  });
}
