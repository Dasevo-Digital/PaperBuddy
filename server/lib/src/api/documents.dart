import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../access.dart';
import '../auth.dart';
import '../db.dart';
import '../history.dart';
import '../processing/consumer.dart';
import '../processing/matching.dart';
import '../processing/pdf_ops.dart';
import '../storage.dart';
import '../trash.dart';
import 'custom_fields.dart';
import 'http_utils.dart';

/// `/api/documents/…` inklusive Upload, Downloads, Notizen, Bulk-Edit und
/// Papierkorb, mit Modell- und Objektrechten.
class DocumentsResource {
  DocumentsResource({
    required this.db,
    required this.store,
    required this.consumer,
    required this.access,
    required this.customFields,
    required this.trash,
    this.pdf,
    this.history,
    this.onUpdated,
  });

  final Database db;
  final BlobStore store;
  final Consumer consumer;
  final Access access;
  final CustomFieldsResource customFields;
  final Trash trash;
  final PdfOperations? pdf;
  final History? history;

  /// Wird nach jeder Änderung an einem Dokument aufgerufen (Workflows).
  final Future<void> Function(int documentId)? onUpdated;

  static const _model = 'document';
  static const _select = '''
    SELECT d.*,
      (SELECT group_concat(tag_id) FROM document_tags WHERE document_id = d.id) AS tag_ids
    FROM documents d''';

  Row? _row(int id) => db.select('$_select WHERE d.id = ?', [id]).firstOrNull;

  User _user(Request r) => r.context['user'] as User;

  /// Sichtbares Dokument aus der URL; Dokumente im Papierkorb gelten als
  /// nicht vorhanden.
  Row _require(Request request) {
    final user = _user(request);
    final row = db.select(
      '$_select WHERE d.id = ? AND d.deleted_at IS NULL AND ${access.visibleSql(user, _model, 'd')}',
      [int.parse(request.params['id']!)],
    ).firstOrNull;
    return row ?? (throw ApiError.notFound());
  }

  void _requireChange(User user, Row row) {
    access.require(user, 'change', _model);
    if (!access.canChange(user, _model, row['id'] as int, row['owner'] as int?)) {
      throw Access.forbidden();
    }
  }

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

  Map<String, dynamic> serialize(Row row, Request request, {Map<String, dynamic>? searchHit}) {
    final q = request.url.queryParameters;
    final user = _user(request);
    final id = row['id'] as int;
    final owner = row['owner'] as int?;
    final created = row['created'] as String;
    var content = row['content'] as String;
    if (asBool(q['truncate_content']) && content.length > 300) {
      content = content.substring(0, 300);
    }
    final tags = (row['tag_ids'] as String?)?.split(',').map(int.parse).toList() ?? <int>[];
    final archivePath = row['archive_path'] as String?;
    final out = <String, dynamic>{
      'id': id,
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
      'deleted_at': row['deleted_at'],
      'archive_serial_number': row['archive_serial_number'],
      'original_file_name': row['original_filename'],
      'archived_file_name': archivePath == null
          ? null
          : '${p.basenameWithoutExtension(row['original_filename'] as String)}.pdf',
      'owner': owner,
      'user_can_change': access.canChange(user, _model, id, owner),
      'is_shared_by_requester': owner == user.id && access.hasShares(_model, id),
      'notes': access.has(user, 'view', 'note') ? _notes(id) : <Object>[],
      'custom_fields': customFields.valuesOf(id),
      'page_count': row['page_count'],
      'mime_type': row['mime_type'],
      'versions': _versions(id),
    };
    if (asBool(q['full_perms'])) out['permissions'] = access.permissionsJson(_model, id);
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
    'deleted_at': 'd.deleted_at',
    'archive_serial_number': 'd.archive_serial_number',
    'page_count': 'd.page_count',
    'mime_type': 'd.mime_type',
    'owner': 'd.owner',
    'correspondent__name': '(SELECT name FROM correspondents WHERE id = d.correspondent_id) COLLATE NOCASE',
    'document_type__name': '(SELECT name FROM document_types WHERE id = d.document_type_id) COLLATE NOCASE',
    'storage_path__name': '(SELECT name FROM storage_paths WHERE id = d.storage_path_id) COLLATE NOCASE',
    'num_notes': '(SELECT COUNT(*) FROM notes WHERE document_id = d.id)',
  };

  /// Baut die WHERE-Bedingungen aus den Query-Parametern (ohne Sichtbarkeit).
  void _filters(Map<String, String> q, List<String> where, List<Object?> args) {
    void fk(String param, String column) {
      if (q.containsKey('${param}__id')) {
        where.add('d.$column = ?');
        args.add(asInt(q['${param}__id']));
      }
      final inIds = asIntList(q['${param}__id__in']);
      if (inIds.isNotEmpty) where.add('d.$column IN (${inIds.join(',')})');
      final noneIds = asIntList(q['${param}__id__none']);
      if (noneIds.isNotEmpty) {
        where.add('(d.$column IS NULL OR d.$column NOT IN (${noneIds.join(',')}))');
      }
      if (q.containsKey('${param}__isnull')) {
        where.add(asBool(q['${param}__isnull']) ? 'd.$column IS NULL' : 'd.$column IS NOT NULL');
      }
    }

    fk('correspondent', 'correspondent_id');
    fk('document_type', 'document_type_id');
    fk('storage_path', 'storage_path_id');
    fk('owner', 'owner');

    final sharedBy = asInt(q['shared_by__id']);
    if (sharedBy != null) {
      where.add("d.owner = $sharedBy AND EXISTS (SELECT 1 FROM object_permissions op "
          "WHERE op.object_type = 'document' AND op.object_id = d.id)");
    }

    const hasTag = 'EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id AND dt.tag_id';
    for (final id in [...asIntList(q['tags__id__all']), ?asInt(q['tags__id'])]) {
      where.add('$hasTag = $id)');
    }
    final anyTags = asIntList(q['tags__id__in']);
    if (anyTags.isNotEmpty) where.add('$hasTag IN (${anyTags.join(',')}))');
    final noTags = asIntList(q['tags__id__none']);
    if (noTags.isNotEmpty) where.add('NOT $hasTag IN (${noTags.join(',')}))');
    if (q.containsKey('is_tagged')) {
      const tagged = 'EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id)';
      where.add(asBool(q['is_tagged']) ? tagged : 'NOT $tagged');
    }
    if (q.containsKey('is_in_inbox')) {
      const inbox = 'EXISTS (SELECT 1 FROM document_tags dt JOIN tags t ON t.id = dt.tag_id '
          'WHERE dt.document_id = d.id AND t.is_inbox_tag = 1)';
      where.add(asBool(q['is_in_inbox']) ? inbox : 'NOT $inbox');
    }

    // Custom Fields
    const hasField = 'EXISTS (SELECT 1 FROM document_custom_fields cf WHERE cf.document_id = d.id';
    for (final id in asIntList(q['custom_fields__id__all'])) {
      where.add('$hasField AND cf.field_id = $id)');
    }
    final anyFields = asIntList(q['custom_fields__id__in']);
    if (anyFields.isNotEmpty) where.add('$hasField AND cf.field_id IN (${anyFields.join(',')}))');
    final noFields = asIntList(q['custom_fields__id__none']);
    if (noFields.isNotEmpty) where.add('NOT $hasField AND cf.field_id IN (${noFields.join(',')}))');
    if (q.containsKey('has_custom_fields')) {
      where.add(asBool(q['has_custom_fields']) ? '$hasField)' : 'NOT $hasField)');
    }
    final cfText = q['custom_fields__icontains'];
    if (cfText != null && cfText.isNotEmpty) {
      where.add("$hasField AND CAST(json_extract(cf.value, '\$') AS TEXT) LIKE ?)");
      args.add('%$cfText%');
    }
    final cfQuery = q['custom_field_query'];
    if (cfQuery != null && cfQuery.isNotEmpty) {
      Object? parsed;
      try {
        parsed = jsonDecodeLenient(cfQuery);
      } on FormatException {
        throw ApiError.badRequest({'custom_field_query': ['Invalid JSON.']});
      }
      where.add(customFields.queryToSql(parsed, args));
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
      where.add(asBool(q['archive_serial_number__isnull'])
          ? 'd.archive_serial_number IS NULL'
          : 'd.archive_serial_number IS NOT NULL');
    }
    for (final (op, sql) in [('gt', '>'), ('gte', '>='), ('lt', '<'), ('lte', '<=')]) {
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
  }

  Response list(Request request) => _list(request, trashed: false);

  Response _list(Request request, {required bool trashed}) {
    final user = _user(request);
    access.require(user, 'view', _model);
    final q = request.url.queryParameters;
    final where = <String>[
      trashed ? 'd.deleted_at IS NOT NULL' : 'd.deleted_at IS NULL',
      trashed ? access.changeableSql(user, _model, 'd') : access.visibleSql(user, _model, 'd'),
    ];
    final args = <Object?>[];
    _filters(q, where, args);

    // Volltextsuche über FTS5.
    // `text` (API v10) sucht wie `query` in Titel und Inhalt.
    final query = (q['query'] ?? q['text'] ?? '').trim();
    final ftsQuery = query.isEmpty ? null : toFtsQuery(query);
    var from = 'documents d';
    var select = 'd.id';
    if (ftsQuery != null) {
      from = 'documents d JOIN documents_fts ON documents_fts.rowid = d.id';
      select = 'd.id, bm25(documents_fts) AS score, '
          "snippet(documents_fts, 1, '<span class=\"match\">', '</span>', ' … ', 24) AS highlights";
      where.add('documents_fts MATCH ?');
      args.add(ftsQuery);
    }

    var ordering = q['ordering'] ?? (ftsQuery != null ? 'score' : (trashed ? '-deleted_at' : '-created'));
    final desc = ordering.startsWith('-');
    ordering = ordering.replaceFirst('-', '');
    final String orderSql;
    if (ordering == 'score' && ftsQuery != null) {
      orderSql = 'score ${desc ? 'DESC' : 'ASC'}';
    } else {
      orderSql = '${_orderings[ordering] ?? 'd.created'} ${desc ? 'DESC' : 'ASC'}';
    }

    final hits = db.select(
      'SELECT $select FROM $from WHERE ${where.join(' AND ')} ORDER BY $orderSql, d.id DESC',
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

  Response get(Request request) {
    access.require(_user(request), 'view', _model);
    return json(serialize(_require(request), request));
  }

  // ---------------------------------------------------------------------------
  // Ändern / Löschen

  Future<Response> update(Request request) async {
    final user = _user(request);
    final row = _require(request);
    _requireChange(user, row);
    final id = row['id'] as int;
    final body = await readBody(request);
    final owner = row['owner'] as int?;
    final isOwner = user.isSuperuser || owner == null || owner == user.id;
    if (!isOwner) body.remove('owner');
    final before = history?.snapshot(id);
    _applyChanges(id, body);
    if (isOwner && body.containsKey('set_permissions')) {
      access.setPermissions(_model, id, body['set_permissions']);
    }
    await onUpdated?.call(id);
    history?.recordUpdate(id, before, actor: user.id);
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
      if (body.containsKey(field)) values[dbColumn[field] ?? field] = convert(body[field]);
    });
    if (values.containsKey('created') && values['created'] == null) values.remove('created');

    db.execute('BEGIN;');
    try {
      if (values.isNotEmpty) {
        final cols = values.keys.toList();
        db.execute(
          'UPDATE documents SET ${cols.map((c) => '$c = ?').join(', ')}, modified = ? WHERE id = ?',
          [for (final c in cols) values[c], nowIso(), id],
        );
      }
      if (body.containsKey('tags')) {
        db.execute('DELETE FROM document_tags WHERE document_id = ?', [id]);
        _addTags([id], asIntList(body['tags']));
      }
      if (asBool(body['remove_inbox_tags'])) {
        db.execute(
          'DELETE FROM document_tags WHERE document_id = ? AND tag_id IN '
          '(SELECT id FROM tags WHERE is_inbox_tag = 1)',
          [id],
        );
      }
      if (body.containsKey('custom_fields')) customFields.replaceValues(id, body['custom_fields']);
      db.execute('UPDATE documents SET modified = ? WHERE id = ?', [nowIso(), id]);
      db.execute('COMMIT;');
    } on SqliteException catch (e) {
      db.execute('ROLLBACK;');
      if (e.extendedResultCode == 2067) {
        throw ApiError.badRequest({'archive_serial_number': ['Document with this ASN already exists.']});
      }
      if (e.extendedResultCode == 787) {
        throw ApiError.badRequest({'non_field_errors': ['Invalid reference.']});
      }
      rethrow;
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  PdfOperations get _pdf => pdf ?? (throw ApiError(501, 'PDF editing is not available.'));

  void _addTags(List<int> documents, List<int> tags) {
    final stmt = db.prepare(
      'INSERT OR IGNORE INTO document_tags (document_id, tag_id) SELECT ?, id FROM tags WHERE id = ?',
    );
    for (final d in documents) {
      for (final t in tags) {
        stmt.execute([d, t]);
      }
    }
    stmt.close();
  }

  /// Löschen verschiebt in den Papierkorb.
  Response delete(Request request) {
    final user = _user(request);
    final row = _require(request);
    access.require(user, 'delete', _model);
    if (!access.canChange(user, _model, row['id'] as int, row['owner'] as int?)) {
      throw Access.forbidden();
    }
    final before = history?.snapshot(row['id'] as int);
    trash.moveToTrash([row['id'] as int]);
    history?.recordUpdate(row['id'] as int, before, actor: user.id);
    return Response(204);
  }

  Future<Response> bulkEdit(Request request) async {
    final user = _user(request);
    final body = await readBody(request);
    final ids = asIntList(body['documents']);
    final method = body['method'] as String?;
    final params = (body['parameters'] as Map?)?.cast<String, dynamic>() ?? {};
    if (ids.isEmpty || method == null) {
      throw ApiError.badRequest({'documents': ['This field is required.']});
    }
    access.require(user, method == 'delete' ? 'delete' : 'change', _model);
    // Alle Dokumente müssen sichtbar und änderbar sein.
    final rows = db.select(
      'SELECT id, owner FROM documents d WHERE d.id IN (${ids.join(',')}) AND d.deleted_at IS NULL '
      'AND ${access.visibleSql(user, _model, 'd')}',
    );
    if (rows.length != ids.toSet().length) throw ApiError.badRequest({'documents': ['Some documents do not exist.']});
    for (final r in rows) {
      if (!access.canChange(user, _model, r['id'] as int, r['owner'] as int?)) throw Access.forbidden();
    }
    final idList = ids.join(',');
    final before = {for (final id in ids) id: history?.snapshot(id)};
    void touch() => db.execute('UPDATE documents SET modified = ? WHERE id IN ($idList)', [nowIso()]);

    switch (method) {
      case 'set_correspondent' || 'set_document_type' || 'set_storage_path':
        final column = '${method.substring(4)}_id';
        db.execute('UPDATE documents SET $column = ? WHERE id IN ($idList)', [asInt(params[method.substring(4)])]);
        touch();
      case 'add_tag':
        _addTags(ids, [asInt(params['tag'])!]);
        touch();
      case 'remove_tag':
        db.execute('DELETE FROM document_tags WHERE tag_id = ? AND document_id IN ($idList)', [asInt(params['tag'])]);
        touch();
      case 'modify_tags':
        final remove = asIntList(params['remove_tags']);
        if (remove.isNotEmpty) {
          db.execute('DELETE FROM document_tags WHERE document_id IN ($idList) AND tag_id IN (${remove.join(',')})');
        }
        _addTags(ids, asIntList(params['add_tags']));
        touch();
      case 'modify_custom_fields':
        for (final id in ids) {
          customFields.addValues(id, params['add_custom_fields']);
          customFields.removeFields(id, asIntList(params['remove_custom_fields']));
        }
        touch();
      case 'set_permissions':
        for (final r in rows) {
          final owner = r['owner'] as int?;
          if (!(user.isSuperuser || owner == null || owner == user.id)) throw Access.forbidden();
          if (params.containsKey('owner')) {
            db.execute('UPDATE documents SET owner = ? WHERE id = ?', [asInt(params['owner']), r['id']]);
          }
          access.setPermissions(_model, r['id'] as int, params['set_permissions'], merge: asBool(params['merge']));
        }
      case 'delete':
        trash.moveToTrash(ids);
      case 'reprocess':
        for (final id in ids) {
          await consumer.reprocess(id);
        }
      case 'rotate':
        await _pdf.rotate(ids, asInt(params['degrees']) ?? 90);
      case 'delete_pages':
        if (ids.length != 1) throw ApiError.badRequest({'documents': ['Exactly one document is required.']});
        await _pdf.deletePages(ids.single, asIntList(params['pages']));
      case 'merge':
        access.require(user, 'add', _model);
        final task = await _pdf.merge(ids,
            metadataDocument: asInt(params['metadata_document_id']),
            deleteOriginals: asBool(params['delete_originals']),
            trash: trash.moveToTrash);
        return json({'result': 'OK', 'task_id': task});
      case 'split':
        access.require(user, 'add', _model);
        if (ids.length != 1) throw ApiError.badRequest({'documents': ['Exactly one document is required.']});
        final tasks = await _pdf.split(ids.single, PdfOperations.parseRanges(params['pages']),
            deleteOriginal: asBool(params['delete_originals']), trash: trash.moveToTrash);
        return json({'result': 'OK', 'task_ids': tasks});
      default:
        throw ApiError.badRequest({'method': ['Unsupported method: $method']});
    }
    if (method != 'delete') {
      for (final id in ids) {
        await onUpdated?.call(id);
      }
    }
    for (final id in ids) {
      history?.recordUpdate(id, before[id], actor: user.id);
    }
    return json({'result': 'OK'});
  }

  // ---------------------------------------------------------------------------
  // Papierkorb

  Response trashList(Request request) => _list(request, trashed: true);

  Future<Response> trashAction(Request request) async {
    final user = _user(request);
    access.require(user, 'delete', _model);
    final body = await readBody(request);
    final action = body['action'] as String?;
    final requested = asIntList(body['documents']);
    final allowed = [
      for (final r in db.select(
        'SELECT id FROM documents d WHERE d.deleted_at IS NOT NULL AND ${access.changeableSql(user, _model, 'd')}'
        '${requested.isEmpty ? '' : ' AND d.id IN (${requested.join(',')})'}',
      ))
        r['id'] as int,
    ];
    if (requested.isNotEmpty && allowed.length != requested.toSet().length) {
      throw ApiError.badRequest({'documents': ['Some documents are not in the trash.']});
    }
    switch (action) {
      case 'restore':
        final before = {for (final id in allowed) id: history?.snapshot(id)};
        trash.restore(allowed);
        for (final id in allowed) {
          history?.recordUpdate(id, before[id], actor: user.id);
        }
      case 'empty':
        await trash.purge(allowed);
      default:
        throw ApiError.badRequest({'action': ['Expected "restore" or "empty".']});
    }
    return json({'result': 'OK', 'doc_ids': allowed});
  }

  // ---------------------------------------------------------------------------
  // Dateien

  /// Datei-Pfade des Dokuments oder einer Version (`?version=<id>`).
  ({String original, String? archive, String? thumbnail, String mime, String filename}) _files(Request request, Row row) {
    final v = asInt(request.url.queryParameters['version']);
    if (v != null) {
      final version = db.select('SELECT * FROM document_versions WHERE id = ? AND document_id = ?', [v, row['id']]).firstOrNull ??
          (throw ApiError(404, 'Version not found.'));
      return (
        original: version['original_path'] as String,
        archive: version['archive_path'] as String?,
        thumbnail: version['thumbnail_path'] as String?,
        mime: version['mime_type'] as String,
        filename: version['original_filename'] as String,
      );
    }
    return (
      original: row['original_path'] as String,
      archive: row['archive_path'] as String?,
      thumbnail: row['thumbnail_path'] as String?,
      mime: row['mime_type'] as String,
      filename: row['original_filename'] as String,
    );
  }

  Future<Response> download(Request request, {bool inline = false}) async {
    access.require(_user(request), 'view', _model);
    final row = _require(request);
    final f = _files(request, row);
    final wantOriginal = asBool(request.url.queryParameters['original']);
    if (!wantOriginal && f.archive != null) {
      final file = await store.get(f.archive!);
      if (file != null) {
        return sendFile(file, 'application/pdf', filename: '${p.basenameWithoutExtension(f.filename)}.pdf', inline: inline);
      }
    }
    final file = await store.get(f.original);
    if (file == null) throw ApiError(404, 'File not found.');
    return sendFile(file, f.mime, filename: f.filename, inline: inline);
  }

  Future<Response> thumb(Request request) async {
    access.require(_user(request), 'view', _model);
    final row = _require(request);
    final key = _files(request, row).thumbnail;
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

  // ---------------------------------------------------------------------------
  // Versionen und Verlauf

  List<Map<String, dynamic>> _versions(int id) => [
        for (final v in db.select('SELECT * FROM document_versions WHERE document_id = ? ORDER BY id', [id]))
          {
            'id': v['id'],
            'added': v['added'],
            'version_label': v['version_label'],
            'checksum': v['checksum'],
            'is_root': v['is_root'] == 1,
          },
      ];

  Future<Response> updateVersion(Request request) async {
    final user = _user(request);
    final row = _require(request);
    _requireChange(user, row);
    if (!(request.headers['content-type'] ?? '').startsWith('multipart/form-data')) {
      throw ApiError(415, 'Unsupported media type, multipart/form-data expected.');
    }
    final form = await readMultipart(request);
    final upload = form.files['document'] ?? (throw ApiError.badRequest({'document': ['No file was submitted.']}));
    try {
      final label = form.fields['version_label']?.toString().trim();
      final task = await consumer.submitVersion(row['id'] as int, upload.file,
          originalName: upload.filename, label: (label?.isEmpty ?? true) ? null : label, actor: user.id);
      return json(task);
    } finally {
      for (final f in form.files.values) {
        await f.file.parent.delete(recursive: true);
      }
    }
  }

  /// Ältere Version entfernen (nicht die aktuelle).
  Future<Response> deleteVersion(Request request) async {
    final user = _user(request);
    final row = _require(request);
    _requireChange(user, row);
    final v = db.select('SELECT * FROM document_versions WHERE id = ? AND document_id = ?',
            [int.parse(request.params['version']!), row['id']]).firstOrNull ??
        (throw ApiError(404, 'Version not found.'));
    if (v['original_path'] == row['original_path']) {
      throw ApiError.badRequest({'version': ['The current version cannot be deleted.']});
    }
    db.execute('DELETE FROM document_versions WHERE id = ?', [v['id']]);
    for (final key in [v['original_path'], v['archive_path'], v['thumbnail_path']]) {
      if (key is String && key != row['original_path'] && key != row['archive_path'] && key != row['thumbnail_path']) {
        await store.delete(key);
      }
    }
    return Response(204);
  }

  Response historyOf(Request request) {
    final user = _user(request);
    access.require(user, 'view', _model);
    final row = _require(request);
    // Wie in Paperless: Eigentümer, Superuser oder Recht auf den Verlauf.
    final owner = row['owner'] as int?;
    if (!(user.isSuperuser || owner == null || owner == user.id || access.has(user, 'view', 'history'))) {
      throw Access.forbidden();
    }
    return json(history?.entries(row['id'] as int) ?? const []);
  }

  Future<Response> metadata(Request request) async {
    access.require(_user(request), 'view', _model);
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
    access.require(_user(request), 'view', _model);
    final row = _require(request);
    final content = row['content'] as String;
    final m = matchContent(db, content, classifier: consumer.classifier);
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

  Response notes(Request request) {
    final user = _user(request);
    access.require(user, 'view', _model);
    access.require(user, 'view', 'note');
    return json(_notes(_require(request)['id'] as int));
  }

  Future<Response> addNote(Request request) async {
    final user = _user(request);
    access.require(user, 'add', 'note');
    final row = _require(request);
    final id = row['id'] as int;
    final note = (await readBody(request))['note']?.toString().trim() ?? '';
    if (note.isEmpty) throw ApiError.badRequest({'note': ['This field is required.']});
    db.execute(
      'INSERT INTO notes (document_id, note, created, user_id) VALUES (?, ?, ?, ?)',
      [id, note, nowIso(), user.id],
    );
    return json(_notes(id));
  }

  Response deleteNote(Request request) {
    final user = _user(request);
    access.require(user, 'delete', 'note');
    final id = _require(request)['id'] as int;
    final noteId = asInt(request.url.queryParameters['id']);
    final note = db.select('SELECT user_id FROM notes WHERE id = ? AND document_id = ?', [noteId, id]).firstOrNull;
    if (note == null) throw ApiError(404, 'Not found.');
    // Fremde Notizen löschen nur Superuser.
    if (!user.isSuperuser && note['user_id'] != null && note['user_id'] != user.id) throw Access.forbidden();
    db.execute('DELETE FROM notes WHERE id = ?', [noteId]);
    return json(_notes(id));
  }

  // ---------------------------------------------------------------------------
  // Upload

  Future<Response> postDocument(Request request) async {
    final user = _user(request);
    access.require(user, 'add', _model);
    if (!(request.headers['content-type'] ?? '').startsWith('multipart/form-data')) {
      throw ApiError(415, 'Unsupported media type, multipart/form-data expected.');
    }
    final form = await readMultipart(request);
    final upload = form.files['document'];
    if (upload == null) throw ApiError.badRequest({'document': ['No file was submitted.']});
    try {
      final f = form.fields;
      final created = asDate(f['created']);
      final taskId = await consumer.submit(
        upload.file,
        originalName: upload.filename,
        source: ConsumeSource.api,
        overrides: ConsumeOverrides(
          title: f['title'] as String?,
          created: created == null ? null : DateTime.parse(created),
          correspondent: asInt(f['correspondent']),
          documentType: asInt(f['document_type']),
          storagePath: asInt(f['storage_path']),
          tags: asIntList(f['tags']),
          archiveSerialNumber: asInt(f['archive_serial_number']),
          owner: user.id,
          customFields: f['custom_fields'] == null ? null : asIntList(f['custom_fields']),
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
    access.require(_user(request), 'view', _model);
    final max = db.select('SELECT MAX(archive_serial_number) AS m FROM documents').first['m'] as int?;
    return json((max ?? 0) + 1);
  }

  void mount(void Function(String method, String path, Function handler) route) {
    const doc = '/api/documents/<id|[0-9]+>';
    route('GET', '/api/documents/', list);
    route('POST', '/api/documents/post_document/', postDocument);
    route('POST', '/api/documents/bulk_edit/', bulkEdit);
    route('GET', '/api/documents/next_asn/', nextAsn);
    route('GET', '/api/trash/', trashList);
    route('POST', '/api/trash/', trashAction);
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
    route('GET', '$doc/history/', historyOf);
    route('POST', '$doc/update_version/', updateVersion);
    route('DELETE', '$doc/versions/<version|[0-9]+>/', deleteVersion);
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
  static const maxApiVersion = 10;
  static const defaultApiVersion = 9;
  static const serverVersion = '2.18.0';
}
