import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_api/paperbuddy_api.dart';
import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// Verwaltungsfunktionen des Clients gegen den echten Server.
void main() {
  late Directory tmp;
  late PaperbuddyServer server;
  late HttpServer http;
  late PaperlessClient admin;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('paperbuddy-admin-test-');
    server = await PaperbuddyServer.create(
      Config.fromEnvironment({
        'PAPERBUDDY_DATA_DIR': tmp.path,
        'PAPERBUDDY_ADMIN_USER': 'admin',
        'PAPERBUDDY_ADMIN_PASSWORD': 'geheim123',
      }),
      database: openInMemoryDatabase(),
    );
    http = await io.serve(server.handler, 'localhost', 0);
    admin = await PaperlessClient.login('localhost:${http.port}', 'admin', 'geheim123');
  });

  tearDownAll(() async {
    admin.close();
    await http.close(force: true);
    server.workflows.stop();
    server.db.close();
    await tmp.delete(recursive: true);
  });

  Future<int> upload(PaperlessClient c, String name, String text) async {
    final task = await c.waitForTask(await c.uploadDocument(utf8.encode(text), name),
        interval: const Duration(milliseconds: 50));
    expect(task.status, TaskStatus.success, reason: task.result);
    return task.documentId!;
  }

  test('Labels mit Zuordnungsregeln verwalten', () async {
    final tag = await admin.createLabel(LabelKind.tag, {'name': 'Auto', 'matching_algorithm': 6, 'color': '#33a02c'}) as Tag;
    expect(MatchingAlgorithm.of(tag.matchingAlgorithm), MatchingAlgorithm.auto);
    final updated = await admin.updateLabel(LabelKind.tag, tag.id, {'match': 'Strom', 'matching_algorithm': 1}) as Tag;
    expect(updated.match, 'Strom');
    expect((await admin.labels(LabelKind.tag)).map((l) => l.name), contains('Auto'));
    final path = await admin.createStoragePath('Archiv', '{created_year}/{title}');
    expect(path.path, '{created_year}/{title}');
    await admin.deleteLabel(LabelKind.tag, tag.id);
    expect(await admin.labels(LabelKind.tag), isEmpty);
  });

  test('Benutzer, Gruppen, Freigaben und Papierkorb', () async {
    final group = await admin.createGroup('Familie', ['view_document', 'view_tag', 'view_note']);
    final anna = await admin.createUser({
      'username': 'anna',
      'password': 'passwort123',
      'groups': [group.id],
      'user_permissions': ['add_document', 'change_document', 'delete_document', 'view_paperlesstask'],
    });
    expect(anna.inheritedPermissions, contains('view_document'));
    expect((await admin.users()).map((u) => u.username), containsAll(['admin', 'anna']));

    final annaClient = await PaperlessClient.login('localhost:${http.port}', 'anna', 'passwort123');
    addTearDown(annaClient.close);
    expect(annaClient.user.can('view', 'document'), isTrue);
    expect(annaClient.user.can('view', 'user'), isFalse);

    final adminDoc = await upload(admin, 'geheim.txt', 'Nur für Admin');
    expect((await annaClient.documents()).allIds, isNot(contains(adminDoc)));
    await admin.setDocumentPermissions(adminDoc, ObjectPermissions(viewUsers: {anna.id}));
    final perms = await admin.documentPermissions(adminDoc);
    expect(perms.viewUsers, {anna.id});
    final seen = await annaClient.document(adminDoc);
    expect(seen.userCanChange, isFalse);

    final annaDoc = await upload(annaClient, 'anna.txt', 'Annas Dokument');
    expect((await annaClient.document(annaDoc)).owner, anna.id);
    await annaClient.deleteDocument(annaDoc);
    final trash = await annaClient.trash();
    expect(trash.results.map((d) => d.id), [annaDoc]);
    expect(trash.results.single.deletedAt, isNotNull);
    await annaClient.restoreFromTrash([annaDoc]);
    expect((await annaClient.document(annaDoc)).title, 'anna');
    await annaClient.deleteDocument(annaDoc);
    await annaClient.emptyTrash();
    expect((await annaClient.trash()).count, 0);

    await admin.updateProfile({'first_name': 'Ada'});
    expect((await admin.profile()).firstName, 'Ada');
    await admin.deleteUser(anna.id);
    await admin.deleteGroup(group.id);
  });

  test('Custom Fields und gespeicherte Ansichten', () async {
    final betrag = await admin.createCustomField('Betrag', CustomFieldType.monetary, defaultCurrency: 'EUR');
    final status = await admin.createCustomField('Status', CustomFieldType.select, options: ['offen', 'bezahlt']);
    expect(status.options.map((o) => o.label), ['offen', 'bezahlt']);
    final renamed = await admin.updateCustomField(status.id,
        name: 'Zahlstatus', options: [...status.options, const SelectOption('', 'gemahnt')]);
    expect(renamed.options, hasLength(3));
    expect(renamed.options.first.id, status.options.first.id, reason: 'vorhandene IDs bleiben');

    final id = await upload(admin, 'rechnung.txt', 'Rechnung über 50 Euro');
    final doc = await admin.updateDocument(id, {
      'custom_fields': [
        {'field': betrag.id, 'value': 'EUR50.00'},
        {'field': status.id, 'value': status.options.first.id},
      ],
    });
    expect(doc.customFields.map((f) => f.value), ['EUR50.00', status.options.first.id]);

    final tag = await admin.createTag('Rechnung');
    final filter = DocumentFilter(
      query: 'rechnung',
      tagsAll: {tag.id},
      createdFrom: DateTime(2026, 1, 1),
      createdTo: DateTime(2026, 12, 31),
      ordering: DocumentOrdering.titleAsc,
    );
    final view = await admin.createSavedView('Rechnungen 2026', filter);
    expect((await admin.savedViews()).single.name, 'Rechnungen 2026');
    final back = DocumentFilter.fromSavedView(view);
    expect(back, filter, reason: 'Filter übersteht den Weg über die Filterregeln');
    await admin.deleteSavedView(view.id);
    await admin.deleteCustomField(betrag.id);
  });

  test('Workflows, Freigabelinks, Mailkonto-Fehler, Scanner-Liste', () async {
    final tag = await admin.createTag('Eingang');
    final wf = await admin.saveWorkflow(Workflow(name: 'Alles taggen', triggers: [
      {'type': 1, 'sources': [2], 'filter_filename': '*'},
    ], actions: [
      {'type': 1, 'assign_tags': [tag.id]},
    ]));
    expect(wf.id, isNotNull);
    final id = await upload(admin, 'neu.txt', 'Neues Dokument');
    expect((await admin.document(id)).tags, contains(tag.id));
    wf.enabled = false;
    expect((await admin.saveWorkflow(wf)).enabled, isFalse);
    await admin.deleteWorkflow(wf.id!);

    final link = await admin.createShareLink(id, expiration: DateTime.now().add(const Duration(days: 1)));
    expect((await admin.shareLinks(id)).single.slug, link.slug);
    final url = admin.shareLinkUrl(link);
    final response = await HttpClient().getUrl(url).then((r) => r.close());
    expect(response.statusCode, 200);
    await response.drain<void>();
    await admin.deleteShareLink(link.id);

    await expectLater(
      admin.testMailAccount(const MailAccount(name: 'x', imapServer: 'localhost', imapPort: 1, imapSecurity: 1, username: 'u'),
          password: 'p'),
      throwsA(isA<ApiException>()),
    );
    expect(await admin.scanners(), isA<List<ScannerInfo>>());
  });

  test('Zugriffe: angesehen und heruntergeladen, neueste zuerst', () async {
    final id = await upload(admin, 'zugriff.txt', 'Zugriffsprotokoll');
    await admin.document(id);
    await admin.downloadFile(id);
    final log = await admin.accessLog(id);
    expect([for (final e in log) e.action], ['download', 'view']);
    expect(log.first.actor, 'admin');
    expect(log.first.address, isNull);
    expect(log.first.timestamp, isNotNull);
  });
}
