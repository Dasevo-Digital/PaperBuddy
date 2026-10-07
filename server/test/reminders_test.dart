import 'dart:convert';

import 'package:mailer/mailer.dart' as mail;
import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.close());

  test('Fristen anlegen, filtern, abhaken; nur für den Ersteller sichtbar', () async {
    final doc = await env.upload('vertrag.txt', utf8.encode('Mietvertrag Wohnung'));
    final created = await env.json('POST', '/api/reminders/', status: 201, body: {
      'document': doc,
      'due': '2026-11-30',
      'note': 'Kündigungsfrist',
    });
    expect(created['document_title'], 'vertrag');
    expect(created['done'], isFalse);
    await env.json('POST', '/api/reminders/', status: 201, body: {'document': doc, 'due': '2027-03-01'});

    final due = await env.json('GET', '/api/reminders/?done=false&due__lte=2026-12-31');
    expect([for (final r in due['results']) r['note']], ['Kündigungsfrist']);
    final forDoc = await env.json('GET', '/api/reminders/?document=$doc');
    expect(forDoc['count'], 2);

    final id = created['id'];
    final done = await env.json('PATCH', '/api/reminders/$id/', body: {'done': true});
    expect(done['done'], isTrue);
    expect((await env.json('GET', '/api/reminders/?done=false'))['count'], 1);

    // Andere Benutzer sehen fremde Fristen nicht.
    env.addUser('bob', permissions: ['view_document']);
    expect((await env.json('GET', '/api/reminders/', as: 'bob'))['count'], 0);
    await env.json('GET', '/api/reminders/$id/', as: 'bob', status: 404);

    await env.json('POST', '/api/reminders/', status: 400, body: {'document': doc, 'due': 'morgen'});
    await env.json('DELETE', '/api/reminders/$id/', status: 204);
    expect((await env.json('GET', '/api/reminders/'))['count'], 1);
  });

  test('E-Mail am Fälligkeitstag, je Benutzer gesammelt und nur einmal', () async {
    final doc = await env.upload('vertrag.txt', utf8.encode('Mietvertrag Wohnung'));
    env.server.db.execute("UPDATE users SET email = 'admin@example.org' WHERE username = 'admin'");
    for (final (due, note) in [('2026-11-30', 'Kündigen'), ('2026-11-29', 'Zählerstand'), ('2027-01-01', 'Später')]) {
      await env.json('POST', '/api/reminders/', status: 201, body: {'document': doc, 'due': due, 'note': note});
    }
    final sent = <mail.Message>[];
    final reminders = Reminders(
      db: env.server.db,
      access: env.server.access,
      send: (m) async => sent.add(m),
    );
    expect(await reminders.notifyDue(today: DateTime(2026, 11, 30)), 1);
    expect(sent.single.subject, '2 Fristen fällig');
    expect(sent.single.text, allOf(contains('Kündigen'), contains('Zählerstand'), isNot(contains('Später'))));
    // Schon gemeldet: kein zweites Mal.
    expect(await reminders.notifyDue(today: DateTime(2026, 11, 30)), 0);
  });
}
