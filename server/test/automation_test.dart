import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:paperbuddy_server/src/mail/imap_client.dart';
import 'package:paperbuddy_server/src/mail/mime_message.dart';
import 'package:paperbuddy_server/src/processing/classifier.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.close());

  group('Workflows', () {
    test('Verarbeitung gestartet: Dateiname → Tags, Titel-Vorlage, Custom Field', () async {
      final tag = await env.json('POST', '/api/tags/', body: {'name': 'Finanzen'}, status: 201);
      final corr = await env.json('POST', '/api/correspondents/', body: {'name': 'Stadtwerke', 'match': 'Stadtwerke', 'matching_algorithm': 1}, status: 201);
      final field = await env.json('POST', '/api/custom_fields/', body: {'name': 'Geprüft', 'data_type': 'boolean'}, status: 201);
      // Ungültig: Verarbeitungs-Auslöser ohne Filter
      await env.json('POST', '/api/workflows/', body: {
        'name': 'kaputt',
        'triggers': [{'type': 1}],
        'actions': [{'type': 1}],
      }, status: 400);
      final wf = await env.json('POST', '/api/workflows/', body: {
        'name': 'Rechnungen',
        'triggers': [
          {'type': 1, 'sources': [2], 'filter_filename': '*rechnung*'},
        ],
        'actions': [
          {
            'type': 1,
            'assign_title': '{correspondent} {created_year}-{created_month}',
            'assign_tags': [tag['id']],
            'assign_custom_fields': [field['id']],
            'assign_custom_fields_values': {'${field['id']}': true},
          },
        ],
      }, status: 201);
      expect(wf['triggers'].single['filter_filename'], '*rechnung*');
      expect(wf['actions'].single['assign_tags'], [tag['id']]);

      final id = (await env.uploadText('Strom-Rechnung.txt', 'Stadtwerke Musterstadt 15.09.2026'))!;
      final doc = await env.json('GET', '/api/documents/$id/');
      expect(doc['title'], 'Stadtwerke 2026-09');
      expect(doc['correspondent'], corr['id']);
      expect(doc['tags'], contains(tag['id']));
      expect(doc['custom_fields'], [{'field': field['id'], 'value': true}]);

      final other = (await env.uploadText('brief.txt', 'Ein Brief'))!;
      expect((await env.json('GET', '/api/documents/$other/'))['tags'], isNot(contains(tag['id'])));

      // Deaktiviert greift er nicht.
      await env.json('PATCH', '/api/workflows/${wf['id']}/', body: {'enabled': false});
      final third = (await env.uploadText('noch-eine-rechnung.txt', 'Stadtwerke 01.01.2026'))!;
      expect((await env.json('GET', '/api/documents/$third/'))['title'], 'noch-eine-rechnung');
    });

    test('Dokument geändert: Tag-Filter → Entfernen und Webhook', () async {
      final received = Completer<shelf.Request>();
      String? body;
      final hook = await io.serve((shelf.Request r) async {
        body = await r.readAsString();
        if (!received.isCompleted) received.complete(r);
        return shelf.Response.ok('ok');
      }, 'localhost', 0);
      addTearDown(() => hook.close(force: true));

      final erledigt = await env.json('POST', '/api/tags/', body: {'name': 'Erledigt'}, status: 201);
      final inbox = await env.json('POST', '/api/tags/', body: {'name': 'Posteingang', 'is_inbox_tag': true}, status: 201);
      await env.json('POST', '/api/workflows/', body: {
        'name': 'Erledigt räumt auf',
        'triggers': [
          {'type': 3, 'filter_has_tags': [erledigt['id']]},
        ],
        'actions': [
          {'type': 2, 'remove_tags': [inbox['id']]},
          {
            'type': 4,
            'webhook': {'url': 'http://localhost:${hook.port}/hook', 'body': '{"titel": "{doc_title}"}'},
          },
        ],
      }, status: 201);
      final id = (await env.uploadText('aufgabe.txt', 'Aufgabe'))!;
      expect((await env.json('GET', '/api/documents/$id/'))['tags'], [inbox['id']]);
      await env.json('PATCH', '/api/documents/$id/', body: {'tags': [inbox['id'], erledigt['id']]});
      expect((await env.json('GET', '/api/documents/$id/'))['tags'], [erledigt['id']]);
      final request = await received.future.timeout(const Duration(seconds: 5));
      expect(request.method, 'POST');
      expect(jsonDecode(body!), {'titel': 'aufgabe'});
    });

    test('Zeitgesteuert: nach Tagen, einmalig und wiederkehrend', () async {
      final tag = await env.json('POST', '/api/tags/', body: {'name': 'Wiedervorlage'}, status: 201);
      await env.json('POST', '/api/workflows/', body: {
        'name': 'Wiedervorlage',
        'triggers': [
          {'type': 4, 'schedule_date_field': 'added', 'schedule_offset_days': 30},
        ],
        'actions': [
          {'type': 1, 'assign_tags': [tag['id']]},
        ],
      }, status: 201);
      final id = (await env.uploadText('vertrag.txt', 'Vertrag'))!;
      final wf = env.server.workflows;
      expect(await wf.runScheduled(), 0, reason: 'noch nicht fällig');
      expect(await wf.runScheduled(now: DateTime.now().add(const Duration(days: 31))), 1);
      expect((await env.json('GET', '/api/documents/$id/'))['tags'], contains(tag['id']));
      expect(await wf.runScheduled(now: DateTime.now().add(const Duration(days: 60))), 0, reason: 'einmalig');
    });

    test('Platzhalter', () async {
      final id = (await env.uploadText('scan_001.txt', 'Text vom 03.02.2025'))!;
      final out = env.server.workflows.render('{original_filename}|{created}|{created_month_name}|{{ doc_id }}|{unbekannt}', id);
      expect(out, 'scan_001|2025-02-03|February|$id|{unbekannt}');
    });
  });

  test('Lernendes Matching ordnet nach Beispielen zu', () async {
    final corrA = await env.json('POST', '/api/correspondents/', body: {'name': 'Versicherung', 'matching_algorithm': 6}, status: 201);
    final corrB = await env.json('POST', '/api/correspondents/', body: {'name': 'Zahnarzt', 'matching_algorithm': 6}, status: 201);
    final tag = await env.json('POST', '/api/tags/', body: {'name': 'Gesundheit', 'matching_algorithm': 6}, status: 201);
    final samples = {
      corrA['id']: ['Police Haftpflicht Beitrag Versicherungsschein', 'Beitragsrechnung Hausrat Police', 'Versicherungsschein Kfz Police Beitrag'],
      corrB['id']: ['Zahnreinigung Behandlung Praxis Termin', 'Kontrolle Zähne Behandlung Praxis', 'Füllung Zahn Behandlung Rechnung Praxis'],
    };
    var n = 0;
    for (final e in samples.entries) {
      for (final text in e.value) {
        final id = (await env.uploadText('s${n++}.txt', text))!;
        await env.json('PATCH', '/api/documents/$id/', body: {
          'correspondent': e.key,
          if (e.key == corrB['id']) 'tags': [tag['id']],
        });
      }
    }
    final neu = (await env.uploadText('neu.txt', 'Rechnung über Behandlung in unserer Praxis'))!;
    final doc = await env.json('GET', '/api/documents/$neu/');
    expect(doc['correspondent'], corrB['id']);
    expect(doc['tags'], contains(tag['id']));
    final neu2 = (await env.uploadText('neu2.txt', 'Ihre neue Police und der Beitrag'))!;
    expect((await env.json('GET', '/api/documents/$neu2/'))['correspondent'], corrA['id']);
    final sugg = await env.json('GET', '/api/documents/$neu/suggestions/');
    expect(sugg['correspondents'], [corrB['id']]);
    expect(DocumentClassifier.tokenize('Die Rechnung 2026 der Firma'), {'rechnung': 1, 'firma': 1});
  });

  group('MIME', () {
    test('Anhänge, kodierte Namen, Quoted-Printable, Absender', () {
      final pdf = base64.encode(utf8.encode('%PDF-1.4 test'));
      final raw = [
        'From: =?UTF-8?B?U3RhZHR3ZXJrZSBNw7xuY2hlbg==?= <rechnung@stadtwerke.example>',
        'To: ich@example.org',
        'Subject: =?ISO-8859-1?Q?Ihre_Rechnung_f=FCr_M=E4rz?=',
        'Date: Tue, 03 Mar 2026 10:15:00 +0100',
        'Message-ID: <abc@example>',
        'MIME-Version: 1.0',
        'Content-Type: multipart/mixed; boundary="XYZ"',
        '',
        '--XYZ',
        'Content-Type: text/plain; charset=utf-8',
        'Content-Transfer-Encoding: quoted-printable',
        '',
        'Guten Tag, anbei die Rechnung f=C3=BCr M=C3=A4rz.',
        '--XYZ',
        'Content-Type: application/pdf; name="x.pdf"',
        'Content-Disposition: attachment; filename*=UTF-8\'\'Rechnung%20M%C3%A4rz.pdf',
        'Content-Transfer-Encoding: base64',
        '',
        pdf,
        '--XYZ',
        'Content-Type: image/png',
        'Content-Disposition: inline; filename="logo.png"',
        'Content-Transfer-Encoding: base64',
        '',
        base64.encode([137, 80, 78, 71]),
        '--XYZ--',
        '',
      ].join('\r\n');
      final m = MailMessage.parse(bytesOf(raw));
      expect(m.subject, 'Ihre Rechnung für März');
      expect(m.from, ('Stadtwerke München', 'rechnung@stadtwerke.example'));
      expect(m.date, DateTime.utc(2026, 3, 3, 9, 15));
      expect(m.bodyText.trim(), 'Guten Tag, anbei die Rechnung für März.');
      expect(m.attachments().map((a) => a.fileName), ['Rechnung März.pdf']);
      expect(utf8.decode(m.attachments().single.body), '%PDF-1.4 test');
      expect(m.attachments(includeInline: true).map((a) => a.fileName), ['Rechnung März.pdf', 'logo.png']);
    });

    test('Ordnernamen in modifiziertem UTF-7', () {
      expect(ImapClient.encodeMailbox('INBOX'), 'INBOX');
      expect(ImapClient.encodeMailbox('Entwürfe'), 'Entw&APw-rfe');
      expect(ImapClient.encodeMailbox('A&B'), 'A&-B');
    });
  });

  test('eSCL: Fähigkeiten lesen und Scan als PDF übernehmen', () async {
    var jobs = 0;
    var pagesLeft = 2;
    final scanner = await io.serve((shelf.Request r) async {
      final path = r.url.path;
      if (path == 'eSCL/ScannerCapabilities') {
        return shelf.Response.ok('''<?xml version="1.0"?>
<scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:MakeAndModel>Test Scanner 3000</pwg:MakeAndModel>
  <scan:Platen><scan:PlatenInputCaps><scan:SettingProfiles><scan:SettingProfile>
    <scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode><scan:ColorMode>Grayscale8</scan:ColorMode></scan:ColorModes>
    <scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat></scan:DocumentFormats>
    <scan:SupportedResolutions><scan:DiscreteResolutions>
      <scan:DiscreteResolution><scan:XResolution>150</scan:XResolution><scan:YResolution>150</scan:YResolution></scan:DiscreteResolution>
      <scan:DiscreteResolution><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
    </scan:DiscreteResolutions></scan:SupportedResolutions>
  </scan:SettingProfile></scan:SettingProfiles></scan:PlatenInputCaps></scan:Platen>
  <scan:Adf><scan:AdfSimplexInputCaps/><scan:AdfDuplexInputCaps/></scan:Adf>
</scan:ScannerCapabilities>''', headers: {'content-type': 'text/xml'});
      }
      if (path == 'eSCL/ScanJobs' && r.method == 'POST') {
        final xml = await r.readAsString();
        expect(xml, contains('<pwg:InputSource>Feeder</pwg:InputSource>'));
        expect(xml, contains('<scan:Duplex>true</scan:Duplex>'));
        jobs++;
        return shelf.Response(201, headers: {'location': '/eSCL/ScanJobs/job$jobs'});
      }
      if (path.endsWith('/NextDocument')) {
        if (pagesLeft-- <= 0) return shelf.Response.notFound('');
        return shelf.Response.ok(File('test/fixtures/page.jpg').readAsBytesSync(), headers: {'content-type': 'image/jpeg'});
      }
      return shelf.Response.notFound('');
    }, 'localhost', 0);
    addTearDown(() => scanner.close(force: true));

    final service = ScannerService(
      access: env.server.access,
      consumer: env.server.consumer,
      workDir: env.dir.path,
      configured: ScannerService.parseConfig('Büro=http://localhost:${scanner.port}/eSCL'),
      discover: false,
    );
    final list = await service.scanners();
    expect(list.single.name, 'Büro');
    final caps = await service.capabilities(list.single);
    expect(caps.makeAndModel, 'Test Scanner 3000');
    expect(caps.sources, ['Platen', 'Feeder']);
    expect(caps.resolutions, [150, 300]);
    expect(caps.duplex, isTrue);

    final task = await service.scan(list.single, source: 'Feeder', duplex: true, resolution: 600);
    await env.server.consumer.waitFor(task);
    final row = env.server.db.select('SELECT status, related_document, result FROM tasks WHERE task_id = ?', [task]).first;
    expect(row['status'], 'SUCCESS', reason: '${row['result']}');
    final doc = await env.json('GET', '/api/documents/${row['related_document']}/');
    expect(doc['mime_type'], 'application/pdf');
    expect(doc['original_file_name'], startsWith('Scan Büro'));
    service.close();
  });
}
