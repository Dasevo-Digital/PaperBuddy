import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../db.dart';
import '../processing/consumer.dart';
import '../processing/matching.dart';
import '../storage.dart';
import 'http_utils.dart';
import 'taxonomy.dart';

/// `/api/documents/…` inklusive Upload, Downloads, Notizen und Bulk-Edit.
class DocumentsResource {
  DocumentsResource({
    required this.db,
    required this.store,
    required this.consumer,
  });

  final Database db;
  final BlobStore store;
  final Consumer consumer;

  static const _select = '''
    SELECT d.*,
      (SELECT group_concat(tag_id) FROM document_tags WHERE document_id = d.id) AS tag_ids
    FROM documents d''';

  Row? _row(int id) => db.select('$_select WHERE d.id = ?', [id]).firstOrNull;

  Row _require(Request request) =>
      _row(int.parse(request.params['id']!)) ?? (throw ApiError.notFound());

  // ---------------------------------------------------------------------------
  // Serialisierung

  List<Map<String, dynamic>> _notes(int documentId) => [
    for (final n in db.select(
      'SELECT n.*, u.username, u.first_name, u.last_name FROM notes n '
      'LEFT JOIN users u ON u.id = n.user_id WHERE n.document_id = ? '
      'ORDER BY n.created DESC',
      [documentId],
    ))
      {
        'id': n['id'],
        'note': n['note'],
        'created': n['created'],
        'user': n['user_id'] == null
            ? null
            : {
                'id': n['user_id'],
                'username': n['username'],
                'first_name': n['first_name'],
                'last_name': n['last_name'],
              },
      },
  ];

  Map<String, dynamic> serialize(
    Row row,
    Request request, {
    Map<String, dynamic>? searchHit,
  }) {
    final q = request.url.queryParameters;
    final created = row['created'] as String;
    var content = row['content'] as String;
    if (asBool(q['truncate_content']) && content.length > 300) {
      content = content.substring(0, 300);
    }
    final tags =
        (row['tag_ids'] as String?)?.split(',').map(int.parse).toList() ??
        <int>[];
    final archivePath = row['archive_path'] as String?;
    final out = <String, dynamic>{
      'id': row['id'],
      'correspondent': row['correspondent_id'],
      'document_type': row['document_type_id'],
      'storage_path': row['storage_path_id'],
      'title': row['title'],
      'content': content,
      'tags': tags..sort(),
      // Ab API v9 ist `created` ein reines Datum, davor ein Zeitstempel.
      'created': apiVersion(request) >= 9 ? created : '${created}T00:00:00Z',
      'created_date': created,
      'modified': row['modified'],
      'added': row['added'],
      'deleted_at': null,
      'archive_serial_number': row['archive_serial_number'],
      'original_file_name': row['original_filename'],
      'archived_file_name': archivePath == null
          ? null
          : '${p.basenameWithoutExtension(row['original_filename'] as String)}.pdf',
      'owner': row['owner'],
      'user_can_change': true,
      'is_shared_by_requester': false,
      'notes': _notes(row['id'] as int),
      'custom_fields': <Object>[],
      'page_count': row['page_count'],
      'mime_type': row['mime_type'],
    };
    if (asBool(q['full_perms'])) out['permissions'] = emptyPermissions;
    if (searchHit != null) out['__search_hit__'] = searchHit;
    final fields = q['fields'];
    if (fields != null && fields.isNotEmpty) {
      final keep = fields.split(',').toSet();
      out.removeWhere((k, _) => !keep.contains(k));
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Liste mit Filtern

  static const _orderings = {
    'id': 'd.id',
    'title': 'd.title COLLATE NOCASE',
    'created': 'd.created',
    'added': 'd.added',
    'modified': 'd.modified',
    'archive_serial_number': 'd.archive_serial_number',
    'page_count': 'd.page_count',
    'mime_type': 'd.mime_type',
    'correspondent__name':
        '(SELECT name FROM correspondents WHERE id = d.correspondent_id) COLLATE NOCASE',
    'document_type__name':
        '(SELECT name FROM document_types WHERE id = d.document_type_id) COLLATE NOCASE',
    'storage_path__name':
        '(SELECT name FROM storage_paths WHERE id = d.storage_path_id) COLLATE NOCASE',
    'num_notes': '(SELECT COUNT(*) FROM notes WHERE document_id = d.id)',
  };

  Response list(Request request) {
    final q = request.url.queryParameters;
    final where = <String>[];
    final args = <Object?>[];

    void fk(String param, String column) {
      if (q.containsKey('${param}__id')) {
        where.add('d.$column = ?');
        args.add(asInt(q['${param}__id']));
      }
      final inIds = asIntList(q['${param}__id__in']);
      if (inIds.isNotEmpty) where.add('d.$column IN (${inIds.join(',')})');
      final noneIds = asIntList(q['${param}__id__none']);
      if (noneIds.isNotEmpty) {
        where.add(
          '(d.$column IS NULL OR d.$column NOT IN (${noneIds.join(',')}))',
        );
      }
      if (q.containsKey('${param}__isnull')) {
        where.add(
          asBool(q['${param}__isnull'])
              ? 'd.$column IS NULL'
              : 'd.$column IS NOT NULL',
        );
      }
    }

    fk('correspondent', 'correspondent_id');
    fk('document_type', 'document_type_id');
    fk('storage_path', 'storage_path_id');

    const hasTag =
        'EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id AND dt.tag_id';
    for (final id in [
      ...asIntList(q['tags__id__all']),
      ?asInt(q['tags__id']),
    ]) {
      where.add('$hasTag = $id)');
    }
    final anyTags = asIntList(q['tags__id__in']);
    if (anyTags.isNotEmpty) where.add('$hasTag IN (${anyTags.join(',')}))');
    final noTags = asIntList(q['tags__id__none']);
    if (noTags.isNotEmpty) where.add('NOT $hasTag IN (${noTags.join(',')}))');
    if (q.containsKey('is_tagged')) {
      where.add(
        asBool(q['is_tagged'])
            ? 'EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id)'
            : 'NOT EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id)',
      );
    }
    if (q.containsKey('is_in_inbox')) {
      final inbox =
          'EXISTS (SELECT 1 FROM document_tags dt JOIN tags t ON t.id = dt.tag_id '
          'WHERE dt.document_id = d.id AND t.is_inbox_tag = 1)';
      where.add(asBool(q['is_in_inbox']) ? inbox : 'NOT $inbox');
    }

    void text(String param, String sql) {
      final v = q[param];
      if (v == null || v.isEmpty) return;
      where.add(sql);
      final pattern = '%${v.replaceAll('%', '').replaceAll('_', '')}%';
      args.addAll(List.filled('?'.allMatches(sql).length, pattern));
    }

    text('title__icontains', 'd.title LIKE ?');
    text('content__icontains', 'd.content LIKE ?');
    text('title_content', '(d.title LIKE ? OR d.content LIKE ?)');
    text('original_filename__icontains', 'd.original_filename LIKE ?');

    if (q.containsKey('archive_serial_number')) {
      where.add('d.archive_serial_number = ?');
      args.add(asInt(q['archive_serial_number']));
    }
    if (q.containsKey('archive_serial_number__isnull')) {
      where.add(
        asBool(q['archive_serial_number__isnull'])
            ? 'd.archive_serial_number IS NULL'
            : 'd.archive_serial_number IS NOT NULL',
      );
    }
    for (final (op, sql) in [
      ('gt', '>'),
      ('gte', '>='),
      ('lt', '<'),
      ('lte', '<='),
    ]) {
      final asnValue = q['archive_serial_number__$op'];
      if (asnValue != null) {
        where.add('d.archive_serial_number $sql ?');
        args.add(asInt(asnValue));
      }
      for (final field in ['created', 'added', 'modified']) {
        final v = q['${field}__date__$op'] ?? q['${field}__$op'];
        if (v == null || v.isEmpty) continue;
        where.add('substr(d.$field, 1, 10) $sql ?');
        args.add(asDate(v));
      }
    }
    final ids = asIntList(q['id__in']);
    if (ids.isNotEmpty) where.add('d.id IN (${ids.join(',')})');
    if (q.containsKey('id')) {
      where.add('d.id = ?');
      args.add(asInt(q['id']));
    }
    if (q.containsKey('mime_type')) {
      where.add('d.mime_type = ?');
      args.add(q['mime_type']);
    }

    // Volltextsuche über FTS5.
    final query = (q['query'] ?? '').trim();
    final ftsQuery = query.isEmpty ? null : toFtsQuery(query);
    var from = 'documents d';
    var select = 'd.id';
    if (ftsQuery != null) {
      from = 'documents d JOIN documents_fts ON documents_fts.rowid = d.id';
      select =
          'd.id, bm25(documents_fts) AS score, '
          "snippet(documents_fts, 1, '<span class=\"match\">', '</span>', ' … ', 24) AS highlights";
      where.add('documents_fts MATCH ?');
      args.add(ftsQuery);
    }

    var ordering = q['ordering'] ?? (ftsQuery != null ? 'score' : '-created');
    final desc = ordering.startsWith('-');
    ordering = ordering.replaceFirst('-', '');
    final String orderSql;
    if (ordering == 'score' && ftsQuery != null) {
      orderSql = 'score ${desc ? 'DESC' : 'ASC'}';
    } else {
      orderSql =
          '${_orderings[ordering] ?? 'd.created'} ${desc ? 'DESC' : 'ASC'}';
    }

    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final hits = db.select(
      'SELECT $select FROM $from $whereSql ORDER BY $orderSql, d.id DESC',
      args,
    );

    return paginated(request, (limit, offset) {
      final page = hits.skip(offset).take(limit).toList();
      return [
        for (final (i, hit) in page.indexed)
          serialize(
            _row(hit['id'] as int)!,
            request,
            searchHit: ftsQuery == null
                ? null
                : {
                    'score': -(hit['score'] as double),
                    'highlights': hit['highlights'],
                    'note_highlights': '',
                    'rank': offset + i,
                  },
          ),
      ];
    }, allIds: [for (final h in hits) h['id'] as int]);
  }

  Response get(Request request) => json(serialize(_require(request), request));

  // ---------------------------------------------------------------------------
  // Ändern / Löschen

  Future<Response> update(Request request) async {
    final row = _require(request);
    final id = row['id'] as int;
    final body = await readBody(request);
    _applyChanges(id, body);
    return json(serialize(_row(id)!, request));
  }

  void _applyChanges(int id, Map<String, dynamic> body) {
    final columns = <String, Object? Function(Object?)>{
      'title': (v) => v?.toString() ?? '',
      'content': (v) => v?.toString() ?? '',
      'correspondent': asInt,
      'document_type': asInt,
      'storage_path': asInt,
      'archive_serial_number': asInt,
      'owner': asInt,
      'created': asDate,
      'created_date': asDate,
    };
    const dbColumn = {
      'correspondent': 'correspondent_id',
      'document_type': 'document_type_id',
      'storage_path': 'storage_path_id',
      'created_date': 'created',
    };
    final values = <String, Object?>{};
    columns.forEach((field, convert) {
      if (body.containsKey(field)) {
        values[dbColumn[field] ?? field] = convert(body[field]);
      }
    });
    if (values.containsKey('created') && values['created'] == null) {
      values.remove('created');
    }

    db.execute('BEGIN;');
    try {
      if (values.isNotEmpty) {
        final cols = values.keys.toList();
        db.execute(
          'UPDATE documents SET ${cols.map((c) => '$c = ?').join(', ')}, modified = ? '
          'WHERE id = ?',
          [for (final c in cols) values[c], nowIso(), id],
        );
      }
      if (body.containsKey('tags')) {
        db.execute('DELETE FROM document_tags WHERE document_id = ?', [id]);
        _addTags([id], asIntList(body['tags']));
        db.execute('UPDATE documents SET modified = ? WHERE id = ?', [
          nowIso(),
          id,
        ]);
      }
      if (asBool(body['remove_inbox_tags'])) {
        db.execute(
          'DELETE FROM document_tags WHERE document_id = ? AND tag_id IN '
          '(SELECT id FROM tags WHERE is_inbox_tag = 1)',
          [id],
        );
      }
      db.execute('COMMIT;');
    } on SqliteException catch (e) {
      db.execute('ROLLBACK;');
      if (e.extendedResultCode == 2067) {
        throw ApiError.badRequest({
          'archive_serial_number': ['Document with this ASN already exists.'],
        });
      }
      if (e.extendedResultCode == 787) {
        throw ApiError.badRequest({
          'non_field_errors': ['Invalid reference.'],
        });
      }
      rethrow;
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _addTags(List<int> documents, List<int> tags) {
    final stmt = db.prepare(
      'INSERT OR IGNORE INTO document_tags (document_id, tag_id) '
      'SELECT ?, id FROM tags WHERE id = ?',
    );
    for (final d in documents) {
      for (final t in tags) {
        stmt.execute([d, t]);
      }
    }
    stmt.close();
  }

  Future<Response> delete(Request request) async {
    final row = _require(request);
    await _deleteDocument(row);
    return Response(204);
  }

  Future<void> _deleteDocument(Row row) async {
    db.execute('DELETE FROM documents WHERE id = ?', [row['id']]);
    for (final key in [
      row['original_path'],
      row['archive_path'],
      row['thumbnail_path'],
    ]) {
      if (key is String && key.isNotEmpty) await store.delete(key);
    }
  }

  Future<Response> bulkEdit(Request request) async {
    final body = await readBody(request);
    final ids = asIntList(body['documents']);
    final method = body['method'] as String?;
    final params = (body['parameters'] as Map?)?.cast<String, dynamic>() ?? {};
    if (ids.isEmpty || method == null) {
      throw ApiError.badRequest({
        'documents': ['This field is required.'],
      });
    }
    final idList = ids.join(',');
    void touch() => db.execute(
      'UPDATE documents SET modified = ? WHERE id IN ($idList)',
      [nowIso()],
    );

    switch (method) {
      case 'set_correspondent':
      case 'set_document_type':
      case 'set_storage_path':
        final column = '${method.substring(4)}_id';
        db.execute('UPDATE documents SET $column = ? WHERE id IN ($idList)', [
          asInt(params[method.substring(4)]),
        ]);
        touch();
      case 'add_tag':
        _addTags(ids, [asInt(params['tag'])!]);
        touch();
      case 'remove_tag':
        db.execute(
          'DELETE FROM document_tags WHERE tag_id = ? AND document_id IN ($idList)',
          [asInt(params['tag'])],
        );
        touch();
      case 'modify_tags':
        final remove = asIntList(params['remove_tags']);
        if (remove.isNotEmpty) {
          db.execute(
            'DELETE FROM document_tags WHERE document_id IN ($idList) '
            'AND tag_id IN (${remove.join(',')})',
          );
        }
        _addTags(ids, asIntList(params['add_tags']));
        touch();
      case 'delete':
        for (final id in ids) {
          final row = _row(id);
          if (row != null) await _deleteDocument(row);
        }
      default:
        throw ApiError.badRequest({
          'method': ['Unsupported method: $method'],
        });
    }
    return json({'result': 'OK'});
  }

  // ---------------------------------------------------------------------------
  // Dateien

  Future<Response> download(Request request, {bool inline = false}) async {
    final row = _require(request);
    final wantOriginal = asBool(request.url.queryParameters['original']);
    final archive = row['archive_path'] as String?;
    final original = row['original_filename'] as String;
    if (!wantOriginal && archive != null) {
      final file = await store.get(archive);
      if (file != null) {
        return sendFile(
          file,
          'application/pdf',
          filename: '${p.basenameWithoutExtension(original)}.pdf',
          inline: inline,
        );
      }
    }
    final file = await store.get(row['original_path'] as String);
    if (file == null) throw ApiError(404, 'File not found.');
    return sendFile(
      file,
      row['mime_type'] as String,
      filename: original,
      inline: inline,
    );
  }

  Future<Response> thumb(Request request) async {
    final row = _require(request);
    final key = row['thumbnail_path'] as String?;
    final file = key == null ? null : await store.get(key);
    if (file == null) throw ApiError(404, 'Thumbnail not available.');
    final type = switch (p.extension(key!).toLowerCase()) {
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.webp' => 'image/webp',
      '.tiff' || '.tif' => 'image/tiff',
      _ => 'application/octet-stream',
    };
    return sendFile(file, type, filename: p.basename(key), inline: true);
  }

  Future<Response> metadata(Request request) async {
    final row = _require(request);
    final original = await store.get(row['original_path'] as String);
    final archiveKey = row['archive_path'] as String?;
    final archive = archiveKey == null ? null : await store.get(archiveKey);
    return json({
      'original_checksum': row['checksum'],
      'original_size': await original?.length(),
      'original_mime_type': row['mime_type'],
      'media_filename': row['original_path'],
      'has_archive_version': archive != null,
      'original_metadata': <Object>[],
      'archive_checksum': null,
      'archive_media_filename': archiveKey,
      'original_filename': row['original_filename'],
      'archive_size': await archive?.length(),
      'archive_metadata': <Object>[],
      'lang': 'de',
    });
  }

  Response suggestions(Request request) {
    final row = _require(request);
    final content = row['content'] as String;
    final m = matchContent(db, content);
    final date = findDate(content);
    return json({
      'correspondents': [?m.correspondent],
      'tags': m.tags.toList(),
      'document_types': [?m.documentType],
      'storage_paths': [?m.storagePath],
      'dates': [if (date != null) date.toIso8601String().substring(0, 10)],
    });
  }

  // ---------------------------------------------------------------------------
  // Notizen

  Response notes(Request request) =>
      json(_notes(_require(request)['id'] as int));

  Future<Response> addNote(Request request) async {
    final id = _require(request)['id'] as int;
    final note = (await readBody(request))['note']?.toString().trim() ?? '';
    if (note.isEmpty) {
      throw ApiError.badRequest({
        'note': ['This field is required.'],
      });
    }
    db.execute(
      'INSERT INTO notes (document_id, note, created, user_id) VALUES (?, ?, ?, ?)',
      [id, note, nowIso(), (request.context['user'] as User).id],
    );
    return json(_notes(id));
  }

  Response deleteNote(Request request) {
    final id = _require(request)['id'] as int;
    final noteId = asInt(request.url.queryParameters['id']);
    db.execute('DELETE FROM notes WHERE id = ? AND document_id = ?', [
      noteId,
      id,
    ]);
    return json(_notes(id));
  }

  // ---------------------------------------------------------------------------
  // Upload

  Future<Response> postDocument(Request request) async {
    if (!(request.headers['content-type'] ?? '').startsWith(
      'multipart/form-data',
    )) {
      throw ApiError(
        415,
        'Unsupported media type, multipart/form-data expected.',
      );
    }
    final form = await readMultipart(request);
    final upload = form.files['document'];
    if (upload == null) {
      throw ApiError.badRequest({
        'document': ['No file was submitted.'],
      });
    }
    try {
      final f = form.fields;
      final created = asDate(f['created']);
      final taskId = await consumer.submit(
        upload.file,
        originalName: upload.filename,
        overrides: ConsumeOverrides(
          title: f['title'] as String?,
          created: created == null ? null : DateTime.parse(created),
          correspondent: asInt(f['correspondent']),
          documentType: asInt(f['document_type']),
          storagePath: asInt(f['storage_path']),
          tags: asIntList(f['tags']),
          archiveSerialNumber: asInt(f['archive_serial_number']),
          owner: (request.context['user'] as User).id,
        ),
      );
      return json(taskId);
    } finally {
      for (final file in form.files.values) {
        await file.file.parent.delete(recursive: true);
      }
    }
  }

  Response nextAsn(Request request) {
    final max =
        db
                .select('SELECT MAX(archive_serial_number) AS m FROM documents')
                .first['m']
            as int?;
    return json((max ?? 0) + 1);
  }

  void mount(
    void Function(String method, String path, Function handler) route,
  ) {
    const doc = '/api/documents/<id|[0-9]+>';
    route('GET', '/api/documents/', list);
    route('POST', '/api/documents/post_document/', postDocument);
    route('POST', '/api/documents/bulk_edit/', bulkEdit);
    route('GET', '/api/documents/next_asn/', nextAsn);
    route('GET', '$doc/', get);
    route('PUT', '$doc/', update);
    route('PATCH', '$doc/', update);
    route('DELETE', '$doc/', delete);
    route('GET', '$doc/download/', (Request r) => download(r));
    route('GET', '$doc/preview/', (Request r) => download(r, inline: true));
    route('GET', '$doc/thumb/', thumb);
    route('GET', '$doc/metadata/', metadata);
    route('GET', '$doc/suggestions/', suggestions);
    route('GET', '$doc/notes/', notes);
    route('POST', '$doc/notes/', addNote);
    route('DELETE', '$doc/notes/', deleteNote);
  }
}

/// Wandelt eine Suchanfrage in eine sichere FTS5-Abfrage um.
/// Jedes Wort wird als Präfix gesucht, alle Wörter müssen vorkommen.
String? toFtsQuery(String query) {
  final terms = RegExp(
    r'[\p{L}\p{N}]+',
    unicode: true,
  ).allMatches(query).map((m) => '"${m.group(0)}"*').toList();
  return terms.isEmpty ? null : terms.join(' ');
}

/// Vom Client angefragte API-Version (`Accept: application/json; version=9`).
int apiVersion(Request request) {
  final m = RegExp(
    r'version=(\d+)',
  ).firstMatch(request.headers['accept'] ?? '');
  final v = m == null ? null : int.tryParse(m.group(1)!);
  return v ?? PaperlessCompat.defaultApiVersion;
}

abstract final class PaperlessCompat {
  static const minApiVersion = 1;
  static const maxApiVersion = 9;
  static const defaultApiVersion = 9;
  static const serverVersion = '2.18.0';
}
