import 'dart:convert';

import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.close());

  test('Papierkorb: löschen, wiederherstellen, endgültig leeren, Frist', () async {
    final a = (await env.uploadText('a.txt', 'Dokument A'))!;
    final b = (await env.uploadText('b.txt', 'Dokument B'))!;
    await env.json('DELETE', '/api/documents/$a/', status: 204);
    expect((await env.json('GET', '/api/documents/'))['count'], 1);
    await env.json('GET', '/api/documents/$a/', status: 404);
    final trash = await env.json('GET', '/api/trash/');
    expect(trash['all'], [a]);
    expect(trash['results'][0]['deleted_at'], isNotNull);

    // Erneuter Upload derselben Datei: Duplikat mit Hinweis auf Papierkorb.
    expect(await env.uploadText('a2.txt', 'Dokument A'), isNull);
    expect(env.lastTaskResult, contains('trash'));

    await env.json('POST', '/api/trash/', body: {'documents': [a], 'action': 'restore'});
    expect((await env.json('GET', '/api/documents/'))['count'], 2);

    await env.json('POST', '/api/documents/bulk_edit/', body: {'documents': [a, b], 'method': 'delete'});
    expect((await env.json('GET', '/api/trash/'))['count'], 2);
    final original = env.server.db.select('SELECT original_path FROM documents WHERE id = ?', [a]).first['original_path'] as String;
    expect(await env.server.store.get(original), isNotNull);
    await env.json('POST', '/api/trash/', body: {'documents': [a], 'action': 'empty'});
    expect(await env.server.store.get(original), isNull, reason: 'Datei wird mit gelöscht');

    // Abgelaufene Einträge leert der Papierkorb selbst.
    env.server.db.execute("UPDATE documents SET deleted_at = '2000-01-01T00:00:00Z' WHERE id = ?", [b]);
    expect(await env.server.trash.emptyExpired(), 1);
    expect((await env.json('GET', '/api/trash/'))['count'], 0);
    await env.json('POST', '/api/trash/', body: {'action': 'explode'}, status: 400);
  });

  test('Custom Fields: Typen, Prüfung, Filter, Bulk-Edit', () async {
    Future<int> field(String name, String type, [Map<String, dynamic>? extra]) async =>
        (await env.json('POST', '/api/custom_fields/',
            body: {'name': name, 'data_type': type, 'extra_data': ?extra}, status: 201))['id'] as int;
    final betrag = await field('Betrag', 'monetary', {'default_currency': 'EUR'});
    final faellig = await field('Fällig', 'date');
    final bezahlt = await field('Bezahlt', 'boolean');
    final status = await field('Status', 'select', {'select_options': ['offen', 'erledigt']});
    final anzahl = await field('Anzahl', 'integer');
    await env.json('POST', '/api/custom_fields/', body: {'name': 'X', 'data_type': 'banana'}, status: 400);
    await env.json('POST', '/api/custom_fields/', body: {'name': 'Betrag', 'data_type': 'string'}, status: 400);

    final options = (await env.json('GET', '/api/custom_fields/$status/'))['extra_data']['select_options'] as List;
    expect(options.map((o) => o['label']), ['offen', 'erledigt']);
    final offen = options.first['id'];

    final d1 = (await env.uploadText('r1.txt', 'Rechnung eins'))!;
    final d2 = (await env.uploadText('r2.txt', 'Rechnung zwei'))!;
    await env.json('PATCH', '/api/documents/$d1/', body: {
      'custom_fields': [
        {'field': betrag, 'value': 'EUR120.50'},
        {'field': faellig, 'value': '2026-11-01'},
        {'field': bezahlt, 'value': false},
        {'field': status, 'value': offen},
      ],
    });
    await env.json('PATCH', '/api/documents/$d2/', body: {
      'custom_fields': {'$betrag': 'EUR30.00', '$bezahlt': true, '$status': 1},
    });
    final doc1 = await env.json('GET', '/api/documents/$d1/');
    expect(doc1['custom_fields'], containsAll([
      {'field': betrag, 'value': 'EUR120.50'},
      {'field': bezahlt, 'value': false},
    ]));
    final doc2 = await env.json('GET', '/api/documents/$d2/');
    expect((doc2['custom_fields'] as List).firstWhere((f) => f['field'] == status)['value'], options[1]['id'],
        reason: 'Index (alte API) wird in Options-ID umgesetzt');

    // Ungültige Werte
    await env.json('PATCH', '/api/documents/$d1/', body: {'custom_fields': [{'field': anzahl, 'value': 'viele'}]}, status: 400);
    await env.json('PATCH', '/api/documents/$d1/', body: {'custom_fields': [{'field': faellig, 'value': '31.11.2026'}]}, status: 400);
    await env.json('PATCH', '/api/documents/$d1/', body: {'custom_fields': [{'field': betrag, 'value': '12,5 Euro'}]}, status: 400);
    expect((await env.json('GET', '/api/documents/$d1/'))['custom_fields'], hasLength(4), reason: 'nichts geändert');

    Future<List> query(Object q) async =>
        (await env.json('GET', '/api/documents/?custom_field_query=${Uri.encodeQueryComponent(jsonEncode(q))}'))['all'] as List;
    expect(await query(['Betrag', 'gt', 'EUR100']), [d1]);
    expect(await query(['Bezahlt', 'exact', true]), [d2]);
    expect(await query(['AND', [['Betrag', 'gte', 'EUR10'], ['Status', 'exact', offen]]]), [d1]);
    expect(await query(['OR', [['Fällig', 'exists', true], ['Bezahlt', 'exact', true]]]), unorderedEquals([d1, d2]));
    expect(await query(['NOT', ['Fällig', 'exists', true]]), [d2]);
    expect((await env.json('GET', '/api/documents/?custom_fields__id__all=$faellig'))['all'], [d1]);
    expect((await env.json('GET', '/api/documents/?has_custom_fields=false'))['count'], 0);
    await env.json('GET', '/api/documents/?custom_field_query=nonsense', status: 400);

    await env.json('POST', '/api/documents/bulk_edit/', body: {
      'documents': [d1, d2],
      'method': 'modify_custom_fields',
      'parameters': {'add_custom_fields': {'$anzahl': 3}, 'remove_custom_fields': [bezahlt]},
    });
    final after = await env.json('GET', '/api/documents/$d2/');
    expect((after['custom_fields'] as List).map((f) => f['field']), isNot(contains(bezahlt)));
    expect((after['custom_fields'] as List).firstWhere((f) => f['field'] == anzahl)['value'], 3);
    expect((await env.json('GET', '/api/custom_fields/$anzahl/'))['document_count'], 2);

    await env.json('DELETE', '/api/custom_fields/$anzahl/', status: 204);
    expect((await env.json('GET', '/api/documents/$d2/'))['custom_fields'].map((f) => f['field']), isNot(contains(anzahl)));
  });

  test('Gespeicherte Ansichten', () async {
    env.addUser('anna', permissions: ['view_savedview', 'add_savedview', 'change_savedview', 'delete_savedview']);
    final view = await env.json('POST', '/api/saved_views/', as: 'anna', body: {
      'name': 'Rechnungen',
      'show_in_sidebar': true,
      'sort_field': 'created',
      'sort_reverse': true,
      'filter_rules': [
        {'rule_type': 20, 'value': 'rechnung'},
        {'rule_type': 6, 'value': '3'},
      ],
    }, status: 201);
    expect(view['filter_rules'], hasLength(2));
    expect(view['owner'], isNotNull);
    await env.json('POST', '/api/saved_views/', as: 'anna', body: {'name': ''}, status: 400);
    env.addUser('bob', permissions: ['view_savedview']);
    expect((await env.json('GET', '/api/saved_views/', as: 'bob'))['count'], 0);
    await env.json('PATCH', '/api/saved_views/${view['id']}/', as: 'anna', body: {'name': 'Alle Rechnungen'});
    expect((await env.json('GET', '/api/saved_views/${view['id']}/', as: 'anna'))['name'], 'Alle Rechnungen');
    await env.json('DELETE', '/api/saved_views/${view['id']}/', as: 'anna', status: 204);
  });

  test('Freigabelinks: öffentlich abrufbar, Ablauf, Rechte', () async {
    final id = (await env.uploadText('vertrag.txt', 'Mietvertrag Inhalt'))!;
    final link = await env.json('POST', '/api/share_links/', body: {'document': id, 'file_version': 'archive'}, status: 201);
    expect(link['file_version'], 'original', reason: 'ohne Archiv-PDF wird das Original freigegeben');
    final public = await env.call('GET', '/share/${link['slug']}', as: 'niemand');
    expect(public.statusCode, 200);
    expect(await public.readAsString(), 'Mietvertrag Inhalt');
    expect((await env.json('GET', '/api/documents/$id/share_links/') as List), hasLength(1));

    final expired = await env.json('POST', '/api/share_links/',
        body: {'document': id, 'expiration': '2001-01-01T00:00:00Z'}, status: 201);
    expect((await env.call('GET', '/share/${expired['slug']}', as: 'niemand')).statusCode, 404);
    expect((await env.call('GET', '/share/gibtsnicht', as: 'niemand')).statusCode, 404);

    await env.json('DELETE', '/api/documents/$id/', status: 204);
    expect((await env.call('GET', '/share/${link['slug']}', as: 'niemand')).statusCode, 404, reason: 'Papierkorb sperrt Link');
  });

  test('Kompatibilitäts-Endpunkte', () async {
    final config = await env.json('GET', '/api/config/') as List;
    expect(config.single['id'], 1);
    final root = await env.call('GET', '/api/');
    expect(root.headers['x-api-version'], '9');
    expect(root.headers['x-version'], isNotEmpty);
    await env.uploadText('t.txt', 'x');
    final tasks = await env.json('GET', '/api/tasks/') as List;
    await env.json('POST', '/api/acknowledge_tasks/', body: {'tasks': [tasks.first['id']]});
    expect((await env.json('GET', '/api/tasks/?acknowledged=false') as List), isEmpty);
    final meta = await env.json('GET', '/api/documents/${tasks.first['related_document']}/metadata/');
    for (final key in ['original_checksum', 'original_mime_type', 'media_filename', 'has_archive_version', 'original_filename', 'lang']) {
      expect(meta[key], isNotNull, reason: key);
    }
  });

  test('UTF-8-Textdateien und Neuverarbeitung', () async {
    final id = (await env.uploadText('umlaute.txt', 'Grüße aus München – Straße'))!;
    expect((await env.json('GET', '/api/documents/$id/'))['content'], 'Grüße aus München – Straße');
    env.server.db.execute("UPDATE documents SET content = '' WHERE id = ?", [id]);
    await env.json('POST', '/api/documents/bulk_edit/', body: {'documents': [id], 'method': 'reprocess'});
    expect((await env.json('GET', '/api/documents/$id/'))['content'], 'Grüße aus München – Straße');
  });
}
