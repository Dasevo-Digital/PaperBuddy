import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'api/documents.dart' show PaperlessCompat;
import 'db.dart';
import 'processing/consumer.dart';
import 'storage.dart';

final _log = Logger('transfer');

/// Zusammenfassung eines Imports oder Exports.
class TransferReport {
  int users = 0, groups = 0, tags = 0, correspondents = 0, documentTypes = 0, storagePaths = 0;
  int customFields = 0, documents = 0, notes = 0, savedViews = 0, skipped = 0;
  final warnings = <String>[];

  @override
  String toString() => [
        '$documents Dokumente',
        '$tags Tags',
        '$correspondents Korrespondenten',
        '$documentTypes Dokumenttypen',
        '$storagePaths Speicherpfade',
        '$customFields Custom Fields',
        '$notes Notizen',
        '$savedViews Ansichten',
        '$users Benutzer',
        '$groups Gruppen',
        if (skipped > 0) '$skipped übersprungen',
      ].join(', ');
}

/// Export und Import im Format des Paperless-ngx-Exporters
/// (`manifest.json` mit Django-Objekten plus Dateien).
class Transfer {
  Transfer(this.db, this.store);
  final Database db;
  final BlobStore store;

  // ---------------------------------------------------------------------------
  // Export

  Future<TransferReport> export(String targetDir) async {
    final report = TransferReport();
    final dir = Directory(targetDir);
    await dir.create(recursive: true);
    final manifest = <Map<String, dynamic>>[];
    void add(String model, Object pk, Map<String, dynamic> fields) =>
        manifest.add({'model': model, 'pk': pk, 'fields': fields});

    for (final g in db.select('SELECT * FROM groups')) {
      add('auth.group', g['id'] as int, {'name': g['name'], 'permissions': <Object>[]});
      report.groups++;
    }
    for (final u in db.select('SELECT * FROM users')) {
      add('auth.user', u['id'] as int, {
        'password': u['password_hash'],
        'last_login': null,
        'is_superuser': u['is_superuser'] == 1,
        'username': u['username'],
        'first_name': u['first_name'],
        'last_name': u['last_name'],
        'email': u['email'],
        'is_staff': u['is_staff'] == 1,
        'is_active': u['is_active'] == 1,
        'date_joined': u['date_joined'],
        'groups': [
          for (final r in db.select('SELECT group_id FROM user_groups WHERE user_id = ?', [u['id']])) r['group_id'],
        ],
        'user_permissions': <Object>[],
      });
      report.users++;
    }
    Map<String, dynamic> matching(Row r) => {
          'name': r['name'],
          'match': r['match'],
          'matching_algorithm': r['matching_algorithm'],
          'is_insensitive': r['is_insensitive'] == 1,
          'owner': r['owner'],
        };
    for (final r in db.select('SELECT * FROM correspondents')) {
      add('documents.correspondent', r['id'] as int, matching(r));
      report.correspondents++;
    }
    for (final r in db.select('SELECT * FROM document_types')) {
      add('documents.documenttype', r['id'] as int, matching(r));
      report.documentTypes++;
    }
    for (final r in db.select('SELECT * FROM storage_paths')) {
      add('documents.storagepath', r['id'] as int, {...matching(r), 'path': r['path']});
      report.storagePaths++;
    }
    for (final r in db.select('SELECT * FROM tags')) {
      add('documents.tag', r['id'] as int, {...matching(r), 'color': r['color'], 'is_inbox_tag': r['is_inbox_tag'] == 1});
      report.tags++;
    }
    for (final r in db.select('SELECT * FROM custom_fields')) {
      add('documents.customfield', r['id'] as int, {
        'created': r['created'],
        'name': r['name'],
        'data_type': r['data_type'],
        'extra_data': jsonDecode(r['extra_data'] as String),
      });
      report.customFields++;
    }

    for (final d in db.select('SELECT * FROM documents WHERE deleted_at IS NULL ORDER BY id')) {
      final id = d['id'] as int;
      final base = id.toString().padLeft(7, '0');
      final ext = p.extension(d['original_path'] as String);
      final fileName = 'originals/$base$ext';
      final original = await store.get(d['original_path'] as String);
      if (original == null) {
        report.warnings.add('Original von #$id fehlt, übersprungen');
        report.skipped++;
        continue;
      }
      await _copy(original, p.join(targetDir, fileName));
      String? archiveName, thumbName, archiveChecksum;
      if (d['archive_path'] case final String key) {
        final f = await store.get(key);
        if (f != null) {
          archiveName = 'archive/$base.pdf';
          await _copy(f, p.join(targetDir, archiveName));
          archiveChecksum = md5.convert(await f.readAsBytes()).toString();
        }
      }
      if (d['thumbnail_path'] case final String key) {
        final f = await store.get(key);
        if (f != null) {
          thumbName = 'thumbnails/$base${p.extension(key)}';
          await _copy(f, p.join(targetDir, thumbName));
        }
      }
      add('documents.document', id, {
        'correspondent': d['correspondent_id'],
        'storage_path': d['storage_path_id'],
        'title': d['title'],
        'document_type': d['document_type_id'],
        'content': d['content'],
        'mime_type': d['mime_type'],
        'checksum': d['checksum'],
        'archive_checksum': archiveChecksum,
        'page_count': d['page_count'],
        'created': d['created'],
        'modified': d['modified'],
        'storage_type': 'unencrypted',
        'added': d['added'],
        'filename': fileName,
        'archive_filename': archiveName,
        'original_filename': d['original_filename'],
        'archive_serial_number': d['archive_serial_number'],
        'owner': d['owner'],
        'deleted_at': null,
        'tags': [for (final t in db.select('SELECT tag_id FROM document_tags WHERE document_id = ?', [id])) t['tag_id']],
        '__exported_file_name__': fileName,
        '__exported_archive_name__': ?archiveName,
        '__exported_thumbnail_name__': ?thumbName,
      });
      report.documents++;
    }
    for (final n in db.select(
        'SELECT n.* FROM notes n JOIN documents d ON d.id = n.document_id WHERE d.deleted_at IS NULL')) {
      add('documents.note', n['id'] as int,
          {'note': n['note'], 'created': n['created'], 'document': n['document_id'], 'user': n['user_id']});
      report.notes++;
    }
    for (final v in db.select(
        'SELECT f.* FROM document_custom_fields f JOIN documents d ON d.id = f.document_id WHERE d.deleted_at IS NULL')) {
      final type = db.select('SELECT data_type FROM custom_fields WHERE id = ?', [v['field_id']]).first['data_type'];
      final value = v['value'] == null ? null : jsonDecode(v['value'] as String);
      add('documents.customfieldinstance', v['id'] as int, {
        'created': nowIso(),
        'document': v['document_id'],
        'field': v['field_id'],
        _valueColumn(type as String): value,
      });
    }
    for (final s in db.select('SELECT * FROM saved_views')) {
      final id = s['id'] as int;
      add('documents.savedview', id, {
        'name': s['name'],
        'show_on_dashboard': s['show_on_dashboard'] == 1,
        'show_in_sidebar': s['show_in_sidebar'] == 1,
        'sort_field': s['sort_field'],
        'sort_reverse': s['sort_reverse'] == 1,
        'page_size': s['page_size'],
        'display_mode': s['display_mode'],
        'display_fields': s['display_fields'] == null ? null : jsonDecode(s['display_fields'] as String),
        'owner': s['owner'],
      });
      var i = 0;
      for (final rule in jsonDecode(s['filter_rules'] as String) as List) {
        add('documents.savedviewfilterrule', id * 1000 + i++,
            {'saved_view': id, 'rule_type': rule['rule_type'], 'value': rule['value']});
      }
      report.savedViews++;
    }

    await File(p.join(targetDir, 'manifest.json'))
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
    await File(p.join(targetDir, 'metadata.json')).writeAsString(jsonEncode({
      'version': PaperlessCompat.serverVersion,
      'exporter': 'paperbuddy',
    }));
    return report;
  }

  static String _valueColumn(String type) => switch (type) {
        'string' => 'value_text',
        'longtext' => 'value_long_text',
        'url' => 'value_url',
        'date' => 'value_date',
        'boolean' => 'value_bool',
        'integer' => 'value_int',
        'float' => 'value_float',
        'monetary' => 'value_monetary',
        'documentlink' => 'value_document_ids',
        'select' => 'value_select',
        _ => 'value_text',
      };

  static Future<void> _copy(File from, String to) async {
    await Directory(p.dirname(to)).create(recursive: true);
    await from.copy(to);
  }

  // ---------------------------------------------------------------------------
  // Import aus einem Export-Ordner

  Future<TransferReport> importDirectory(String sourceDir) async {
    final manifestFile = File(p.join(sourceDir, 'manifest.json'));
    if (!await manifestFile.exists()) throw StateError('Keine manifest.json in $sourceDir');
    final manifest = (jsonDecode(await manifestFile.readAsString()) as List).cast<Map<String, dynamic>>();
    final report = TransferReport();
    final ids = <String, Map<Object, int>>{};
    int? mapped(String model, Object? pk) => pk == null ? null : ids[model]?[pk];
    Iterable<Map<String, dynamic>> of(String model) => manifest.where((m) => m['model'] == model);

    db.execute('BEGIN;');
    try {
      for (final g in of('auth.group')) {
        final name = g['fields']['name'] as String;
        db.execute('INSERT OR IGNORE INTO groups (name) VALUES (?)', [name]);
        (ids['group'] ??= {})[g['pk']] = db.select('SELECT id FROM groups WHERE name = ?', [name]).first['id'] as int;
        report.groups++;
      }
      for (final u in of('auth.user')) {
        final f = u['fields'] as Map<String, dynamic>;
        final existing = db.select('SELECT id FROM users WHERE username = ?', [f['username']]).firstOrNull;
        if (existing != null) {
          (ids['user'] ??= {})[u['pk']] = existing['id'] as int;
          report.warnings.add('Benutzer ${f['username']} existiert bereits, übernommen ohne Änderung');
          continue;
        }
        final hash = '${f['password'] ?? '!'}';
        if (!hash.startsWith('pbkdf2_sha256\$') && hash != '!') {
          report.warnings.add('Passwort von ${f['username']} nutzt ${hash.split('\$').first}; bitte neu setzen');
        }
        db.execute(
          'INSERT INTO users (username, password_hash, first_name, last_name, email, is_superuser, is_staff, '
          'is_active, date_joined) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            f['username'],
            hash.startsWith('pbkdf2_sha256\$') ? hash : '!',
            f['first_name'] ?? '',
            f['last_name'] ?? '',
            f['email'] ?? '',
            f['is_superuser'] == true ? 1 : 0,
            f['is_staff'] == true ? 1 : 0,
            f['is_active'] == false ? 0 : 1,
            f['date_joined'] ?? nowIso(),
          ],
        );
        final id = db.lastInsertRowId;
        (ids['user'] ??= {})[u['pk']] = id;
        for (final g in (f['groups'] as List? ?? const [])) {
          final gid = mapped('group', g);
          if (gid != null) db.execute('INSERT OR IGNORE INTO user_groups (user_id, group_id) VALUES (?, ?)', [id, gid]);
        }
        report.users++;
      }

      int label(String model, String table, Map<String, dynamic> entry, [Map<String, Object?> extra = const {}]) {
        final f = entry['fields'] as Map<String, dynamic>;
        final name = '${f['name']}';
        final existing = db.select('SELECT id FROM $table WHERE name = ?', [name]).firstOrNull;
        if (existing != null) return existing['id'] as int;
        final values = {
          'name': name,
          'match': f['match'] ?? '',
          'matching_algorithm': f['matching_algorithm'] ?? 0,
          'is_insensitive': f['is_insensitive'] == false ? 0 : 1,
          'owner': mapped('user', f['owner']),
          ...extra,
        };
        db.execute(
          'INSERT INTO $table (${values.keys.join(', ')}) VALUES (${List.filled(values.length, '?').join(', ')})',
          values.values.toList(),
        );
        return db.lastInsertRowId;
      }

      for (final e in of('documents.correspondent')) {
        (ids['correspondent'] ??= {})[e['pk']] = label('correspondent', 'correspondents', e);
        report.correspondents++;
      }
      for (final e in of('documents.documenttype')) {
        (ids['documenttype'] ??= {})[e['pk']] = label('documenttype', 'document_types', e);
        report.documentTypes++;
      }
      for (final e in of('documents.storagepath')) {
        (ids['storagepath'] ??= {})[e['pk']] = label('storagepath', 'storage_paths', e, {'path': e['fields']['path'] ?? ''});
        report.storagePaths++;
      }
      for (final e in of('documents.tag')) {
        final f = e['fields'] as Map<String, dynamic>;
        (ids['tag'] ??= {})[e['pk']] = label('tag', 'tags', e, {
          'color': f['color'] ?? '#a6cee3',
          'is_inbox_tag': f['is_inbox_tag'] == true ? 1 : 0,
        });
        report.tags++;
      }
      for (final e in of('documents.customfield')) {
        final f = e['fields'] as Map<String, dynamic>;
        final existing = db.select('SELECT id FROM custom_fields WHERE name = ?', [f['name']]).firstOrNull;
        if (existing != null) {
          (ids['customfield'] ??= {})[e['pk']] = existing['id'] as int;
          continue;
        }
        db.execute('INSERT INTO custom_fields (name, data_type, extra_data, created) VALUES (?, ?, ?, ?)',
            [f['name'], f['data_type'], jsonEncode(f['extra_data'] ?? {}), f['created'] ?? nowIso()]);
        (ids['customfield'] ??= {})[e['pk']] = db.lastInsertRowId;
        report.customFields++;
      }
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }

    // Dokumente einzeln, damit ein defektes Dokument nicht alles abbricht.
    for (final e in of('documents.document')) {
      final f = e['fields'] as Map<String, dynamic>;
      if (f['deleted_at'] != null) continue;
      final original = File(p.join(sourceDir, '${f['__exported_file_name__']}'));
      if (!await original.exists()) {
        report.warnings.add('Datei fehlt für „${f['title']}“');
        report.skipped++;
        continue;
      }
      final archiveName = f['__exported_archive_name__'];
      final thumbName = f['__exported_thumbnail_name__'];
      final id = await insertDocument(
        title: '${f['title']}',
        content: '${f['content'] ?? ''}',
        created: '${f['created']}',
        added: f['added'] as String?,
        modified: f['modified'] as String?,
        mimeType: f['mime_type'] as String?,
        originalFileName: '${f['original_filename'] ?? p.basename(original.path)}',
        asn: f['archive_serial_number'] as int?,
        pageCount: f['page_count'] as int?,
        correspondent: mapped('correspondent', f['correspondent']),
        documentType: mapped('documenttype', f['document_type']),
        storagePath: mapped('storagepath', f['storage_path']),
        owner: mapped('user', f['owner']),
        tags: [for (final t in (f['tags'] as List? ?? const [])) ?mapped('tag', t)],
        original: original,
        archive: archiveName == null ? null : File(p.join(sourceDir, '$archiveName')),
        thumbnail: thumbName == null ? null : File(p.join(sourceDir, '$thumbName')),
        report: report,
      );
      if (id != null) (ids['document'] ??= {})[e['pk']] = id;
    }

    for (final e in of('documents.note')) {
      final f = e['fields'] as Map<String, dynamic>;
      final doc = mapped('document', f['document']);
      if (doc == null) continue;
      db.execute('INSERT INTO notes (document_id, note, created, user_id) VALUES (?, ?, ?, ?)',
          [doc, f['note'], f['created'] ?? nowIso(), mapped('user', f['user'])]);
      report.notes++;
    }
    for (final e in of('documents.customfieldinstance')) {
      final f = e['fields'] as Map<String, dynamic>;
      final doc = mapped('document', f['document']);
      final field = mapped('customfield', f['field']);
      if (doc == null || field == null) continue;
      final value = f.entries.where((x) => x.key.startsWith('value_') && x.value != null).map((x) => x.value).firstOrNull;
      db.execute(
        'INSERT OR REPLACE INTO document_custom_fields (document_id, field_id, value) VALUES (?, ?, ?)',
        [doc, field, value == null ? null : jsonEncode(value)],
      );
    }
    final rules = <Object, List<Map<String, dynamic>>>{};
    for (final e in of('documents.savedviewfilterrule')) {
      final f = e['fields'] as Map<String, dynamic>;
      (rules[f['saved_view']] ??= []).add({'rule_type': f['rule_type'], 'value': f['value']});
    }
    for (final e in of('documents.savedview')) {
      final f = e['fields'] as Map<String, dynamic>;
      // Regeln verweisen auf IDs; Tags/Korrespondenten/Typen umschreiben.
      final mappedRules = [
        for (final r in rules[e['pk']] ?? const <Map<String, dynamic>>[]) _mapRule(r, mapped),
      ];
      db.execute(
        'INSERT INTO saved_views (name, show_on_dashboard, show_in_sidebar, sort_field, sort_reverse, filter_rules, '
        'page_size, display_mode, display_fields, owner) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          f['name'],
          f['show_on_dashboard'] == true ? 1 : 0,
          f['show_in_sidebar'] == true ? 1 : 0,
          f['sort_field'],
          f['sort_reverse'] == true ? 1 : 0,
          jsonEncode(mappedRules),
          f['page_size'],
          f['display_mode'],
          f['display_fields'] == null ? null : jsonEncode(f['display_fields']),
          mapped('user', f['owner']),
        ],
      );
      report.savedViews++;
    }
    return report;
  }

  /// Regeltypen mit Objekt-IDs (Paperless `FILTER_*`).
  static Map<String, dynamic> _mapRule(Map<String, dynamic> r, int? Function(String, Object?) mapped) {
    const tagRules = {6, 17, 22};
    const correspondentRules = {3, 26, 27};
    const typeRules = {4, 28, 29};
    const pathRules = {25, 30, 31};
    final type = r['rule_type'] as int;
    final model = tagRules.contains(type)
        ? 'tag'
        : correspondentRules.contains(type)
            ? 'correspondent'
            : typeRules.contains(type)
                ? 'documenttype'
                : pathRules.contains(type)
                    ? 'storagepath'
                    : null;
    if (model == null || r['value'] == null) return r;
    final id = mapped(model, int.tryParse('${r['value']}'));
    return {'rule_type': type, 'value': id?.toString() ?? r['value']};
  }

  /// Legt ein Dokument samt Dateien an. Liefert `null` bei Duplikaten.
  Future<int?> insertDocument({
    required String title,
    required String content,
    required String created,
    String? added,
    String? modified,
    String? mimeType,
    required String originalFileName,
    int? asn,
    int? pageCount,
    int? correspondent,
    int? documentType,
    int? storagePath,
    int? owner,
    List<int> tags = const [],
    required File original,
    File? archive,
    File? thumbnail,
    required TransferReport report,
  }) async {
    final bytes = await original.readAsBytes();
    final checksum = md5.convert(bytes).toString();
    final duplicate = db.select('SELECT id FROM documents WHERE checksum = ?', [checksum]).firstOrNull;
    if (duplicate != null) {
      report.warnings.add('„$title“ ist bereits vorhanden (#${duplicate['id']})');
      report.skipped++;
      return null;
    }
    final mime = mimeType ?? Consumer.detectMime(originalFileName, bytes);
    final ext = supportedMimeTypes[mime] ?? p.extension(originalFileName).replaceFirst('.', '');
    if (asn != null && db.select('SELECT 1 FROM documents WHERE archive_serial_number = ?', [asn]).isNotEmpty) {
      report.warnings.add('ASN $asn von „$title“ ist schon vergeben und wurde entfernt');
      asn = null;
    }
    final now = nowIso();
    db.execute(
      'INSERT INTO documents (title, content, correspondent_id, document_type_id, storage_path_id, created, '
      'modified, added, archive_serial_number, original_filename, mime_type, checksum, original_path, page_count, owner) '
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', ?, ?)",
      [
        title,
        content,
        correspondent,
        documentType,
        storagePath,
        created.length >= 10 ? created.substring(0, 10) : dateOnly(DateTime.now()),
        modified ?? now,
        added ?? now,
        asn,
        originalFileName,
        mime,
        checksum,
        pageCount,
        owner,
      ],
    );
    final id = db.lastInsertRowId;
    final name = id.toString().padLeft(7, '0');
    final originalKey = 'originals/$name.$ext';
    await store.put(originalKey, original);
    String? archiveKey, thumbKey;
    if (archive != null && await archive.exists()) {
      archiveKey = 'archive/$name.pdf';
      await store.put(archiveKey, archive);
    }
    if (thumbnail != null && await thumbnail.exists()) {
      thumbKey = 'thumbnails/$name${p.extension(thumbnail.path)}';
      await store.put(thumbKey, thumbnail);
    }
    db.execute('UPDATE documents SET original_path = ?, archive_path = ?, thumbnail_path = ? WHERE id = ?',
        [originalKey, archiveKey, thumbKey, id]);
    for (final t in tags) {
      db.execute('INSERT OR IGNORE INTO document_tags (document_id, tag_id) VALUES (?, ?)', [id, t]);
    }
    report.documents++;
    return id;
  }

  // ---------------------------------------------------------------------------
  // Import direkt von einem laufenden Paperless-ngx

  /// Holt Stammdaten und Dokumente über die REST-API eines anderen Servers.
  Future<TransferReport> importFromPaperless(Uri baseUrl, String token,
      {http.Client? client, void Function(String)? progress}) async {
    final c = client ?? http.Client();
    final report = TransferReport();
    final headers = {'authorization': 'Token $token', 'accept': 'application/json; version=5'};
    final base = baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    final tmp = await Directory.systemTemp.createTemp('paperbuddy-import-');

    Future<List<Map<String, dynamic>>> all(String path) async {
      final out = <Map<String, dynamic>>[];
      String? next = '$base/api/$path/?page_size=100';
      while (next != null) {
        final r = await c.get(Uri.parse(next), headers: headers);
        if (r.statusCode != 200) throw HttpException('$path: ${r.statusCode} ${r.body}');
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        out.addAll((j['results'] as List).cast<Map<String, dynamic>>());
        next = j['next'] as String?;
      }
      return out;
    }

    Future<File?> download(String url, String name) async {
      final r = await c.get(Uri.parse(url), headers: headers);
      if (r.statusCode != 200) return null;
      final f = File(p.join(tmp.path, name));
      await f.writeAsBytes(r.bodyBytes);
      return f;
    }

    try {
      final ids = <String, Map<int, int>>{};
      Future<void> labels(String path, String model, String table, [Map<String, Object?> Function(Map<String, dynamic>)? extra]) async {
        for (final o in await all(path)) {
          final name = '${o['name']}';
          final existing = db.select('SELECT id FROM $table WHERE name = ?', [name]).firstOrNull;
          int id;
          if (existing != null) {
            id = existing['id'] as int;
          } else {
            final values = {
              'name': name,
              'match': o['match'] ?? '',
              'matching_algorithm': o['matching_algorithm'] ?? 0,
              'is_insensitive': o['is_insensitive'] == false ? 0 : 1,
              ...?extra?.call(o),
            };
            db.execute('INSERT INTO $table (${values.keys.join(', ')}) VALUES (${List.filled(values.length, '?').join(', ')})',
                values.values.toList());
            id = db.lastInsertRowId;
          }
          (ids[model] ??= {})[o['id'] as int] = id;
        }
      }

      await labels('tags', 'tag', 'tags', (o) => {'color': o['color'] ?? '#a6cee3', 'is_inbox_tag': o['is_inbox_tag'] == true ? 1 : 0});
      report.tags = ids['tag']?.length ?? 0;
      await labels('correspondents', 'correspondent', 'correspondents');
      report.correspondents = ids['correspondent']?.length ?? 0;
      await labels('document_types', 'documenttype', 'document_types');
      report.documentTypes = ids['documenttype']?.length ?? 0;
      await labels('storage_paths', 'storagepath', 'storage_paths', (o) => {'path': o['path'] ?? ''});
      report.storagePaths = ids['storagepath']?.length ?? 0;
      try {
        for (final o in await all('custom_fields')) {
          final existing = db.select('SELECT id FROM custom_fields WHERE name = ?', [o['name']]).firstOrNull;
          if (existing != null) {
            (ids['customfield'] ??= {})[o['id'] as int] = existing['id'] as int;
          } else {
            db.execute('INSERT INTO custom_fields (name, data_type, extra_data, created) VALUES (?, ?, ?, ?)',
                [o['name'], o['data_type'], jsonEncode(o['extra_data'] ?? {}), nowIso()]);
            (ids['customfield'] ??= {})[o['id'] as int] = db.lastInsertRowId;
            report.customFields++;
          }
        }
      } on HttpException {
        report.warnings.add('Custom Fields nicht verfügbar (ältere Paperless-Version)');
      }

      final docs = await all('documents');
      for (final (i, d) in docs.indexed) {
        progress?.call('Dokument ${i + 1}/${docs.length}: ${d['title']}');
        final docId = d['id'] as int;
        final originalName = '${d['original_file_name'] ?? 'dokument-$docId'}';
        final original = await download('$base/api/documents/$docId/download/?original=true', 'o-$docId-${p.basename(originalName)}');
        if (original == null) {
          report.warnings.add('Original von „${d['title']}“ nicht abrufbar');
          report.skipped++;
          continue;
        }
        final archive = d['archived_file_name'] != null
            ? await download('$base/api/documents/$docId/download/', 'a-$docId.pdf')
            : null;
        final thumb = await download('$base/api/documents/$docId/thumb/', 't-$docId.webp');
        int? m(String model, Object? v) => v == null ? null : ids[model]?[v as int];
        final id = await insertDocument(
          title: '${d['title']}',
          content: '${d['content'] ?? ''}',
          created: '${d['created_date'] ?? d['created']}',
          added: d['added'] as String?,
          modified: d['modified'] as String?,
          originalFileName: originalName,
          asn: d['archive_serial_number'] as int?,
          pageCount: d['page_count'] as int?,
          correspondent: m('correspondent', d['correspondent']),
          documentType: m('documenttype', d['document_type']),
          storagePath: m('storagepath', d['storage_path']),
          tags: [for (final t in (d['tags'] as List? ?? const [])) ?m('tag', t)],
          original: original,
          archive: archive,
          thumbnail: thumb,
          report: report,
        );
        if (id == null) continue;
        for (final n in (d['notes'] as List? ?? const [])) {
          db.execute('INSERT INTO notes (document_id, note, created) VALUES (?, ?, ?)',
              [id, (n as Map)['note'], n['created'] ?? nowIso()]);
          report.notes++;
        }
        for (final cf in (d['custom_fields'] as List? ?? const [])) {
          final field = m('customfield', (cf as Map)['field']);
          if (field == null) continue;
          db.execute('INSERT OR REPLACE INTO document_custom_fields (document_id, field_id, value) VALUES (?, ?, ?)',
              [id, field, cf['value'] == null ? null : jsonEncode(cf['value'])]);
        }
      }
    } finally {
      if (client == null) c.close();
      await tmp.delete(recursive: true);
    }
    _log.info('Import abgeschlossen: $report');
    return report;
  }
}
