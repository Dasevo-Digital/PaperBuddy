import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

import 'helpers.dart';

/// Quelle mit Stammdaten, Custom Field, Notiz, Ansicht und Dokumenten.
Future<TestEnv> seeded() async {
  final env = await TestEnv.create();
  final tag = await env.json('POST', '/api/tags/', body: {'name': 'Steuer', 'color': '#ff0000'}, status: 201);
  final corr = await env.json('POST', '/api/correspondents/', body: {'name': 'Finanzamt'}, status: 201);
  final field = await env.json('POST', '/api/custom_fields/', body: {'name': 'Betrag', 'data_type': 'monetary'}, status: 201);
  final id = (await env.uploadText('bescheid.txt', 'Steuerbescheid 2025 vom 12.05.2026',
      fields: {'tags': tag['id'], 'correspondent': corr['id'], 'archive_serial_number': 42}))!;
  await env.json('PATCH', '/api/documents/$id/', body: {
    'custom_fields': [{'field': field['id'], 'value': 'EUR634.00'}],
  });
  await env.json('POST', '/api/documents/$id/notes/', body: {'note': 'Einspruch prüfen'});
  await env.uploadText('zweites.txt', 'Zweites Dokument');
  await env.json('POST', '/api/saved_views/', body: {
    'name': 'Steuer',
    'filter_rules': [{'rule_type': 6, 'value': '${tag['id']}'}],
  }, status: 201);
  env.addUser('anna');
  return env;
}

void main() {
  test('Export und Import im Rundlauf (Paperless-Format)', () async {
    final source = await seeded();
    addTearDown(source.close);
    final exportDir = '${source.dir.path}/export';
    final report = await Transfer(source.server.db, source.server.store).export(exportDir);
    expect(report.documents, 2);
    expect(report.notes, 1);
    final manifest = jsonDecode(await File('$exportDir/manifest.json').readAsString()) as List;
    final doc = manifest.firstWhere((m) => m['model'] == 'documents.document' && m['fields']['title'] == 'bescheid');
    expect(File('$exportDir/${doc['fields']['__exported_file_name__']}').existsSync(), isTrue);
    expect(manifest.where((m) => m['model'] == 'documents.customfieldinstance').single['fields']['value_monetary'], 'EUR634.00');

    final target = await TestEnv.create();
    addTearDown(target.close);
    // Vorhandener Tag mit gleichem Namen wird wiederverwendet.
    await target.json('POST', '/api/tags/', body: {'name': 'Steuer'}, status: 201);
    final imported = await Transfer(target.server.db, target.server.store).importDirectory(exportDir);
    expect(imported.documents, 2);
    expect(imported.users, 1, reason: 'anna neu, admin vorhanden');
    expect(imported.warnings.where((w) => w.contains('admin')), isNotEmpty);

    final docs = await target.json('GET', '/api/documents/?ordering=title');
    final bescheid = (docs['results'] as List).firstWhere((d) => d['title'] == 'bescheid');
    final tags = await target.json('GET', '/api/tags/');
    expect(tags['count'], 1);
    expect(bescheid['tags'], [tags['results'][0]['id']]);
    expect(bescheid['archive_serial_number'], 42);
    expect(bescheid['created'], '2026-05-12');
    expect(bescheid['notes'][0]['note'], 'Einspruch prüfen');
    expect(bescheid['custom_fields'][0]['value'], 'EUR634.00');
    final download = await target.call('GET', '/api/documents/${bescheid['id']}/download/');
    expect(await download.readAsString(), 'Steuerbescheid 2025 vom 12.05.2026');
    final views = await target.json('GET', '/api/saved_views/');
    expect(views['results'][0]['filter_rules'][0]['value'], '${tags['results'][0]['id']}',
        reason: 'Tag-ID in Regel umgeschrieben');

    // Anna kann sich mit ihrem alten Passwort anmelden (PBKDF2 übernommen).
    await target.json('POST', '/api/token/', body: {'username': 'anna', 'password': 'passwort123'});

    // Zweiter Import: alles Duplikate.
    final again = await Transfer(target.server.db, target.server.store).importDirectory(exportDir);
    expect(again.documents, 0);
    expect(again.skipped, 2);
  });

  test('Direktübernahme von einem laufenden Server über die API', () async {
    final source = await seeded();
    addTearDown(source.close);
    final http = await io.serve(source.server.handler, 'localhost', 0);
    addTearDown(() => http.close(force: true));

    final target = await TestEnv.create();
    addTearDown(target.close);
    final messages = <String>[];
    final report = await Transfer(target.server.db, target.server.store).importFromPaperless(
      Uri.parse('http://localhost:${http.port}'),
      source.tokens['admin']!,
      progress: messages.add,
    );
    expect(report.documents, 2);
    expect(report.tags, 1);
    expect(messages, hasLength(2));
    final docs = await target.json('GET', '/api/documents/?query=steuerbescheid');
    final d = docs['results'][0];
    expect(d['correspondent'], isNotNull);
    expect(d['notes'], hasLength(1));
    expect(d['custom_fields'][0]['value'], 'EUR634.00');
    expect(d['content'], contains('Steuerbescheid'));
  });
}
