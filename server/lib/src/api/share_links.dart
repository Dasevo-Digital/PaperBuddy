import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../access.dart';
import '../auth.dart';
import '../db.dart';
import '../storage.dart';
import 'http_utils.dart';

/// Freigabelinks: ein Dokument ohne Anmeldung herunterladen (`/share/<slug>`).
class ShareLinksResource {
  ShareLinksResource(this.db, this.access, this.store);
  final Database db;
  final Access access;
  final BlobStore store;
  static final _random = Random.secure();

  static String _slug() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return List.generate(50, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  Map<String, dynamic> _serialize(Row r) => {
        'id': r['id'],
        'created': r['created'],
        'expiration': r['expiration'],
        'slug': r['slug'],
        'document': r['document_id'],
        'file_version': r['file_version'],
        'owner': r['owner'],
      };

  User _user(Request r) => r.context['user'] as User;

  /// Links zu Dokumenten, die der Benutzer sehen darf.
  String _visible(User u) =>
      'EXISTS (SELECT 1 FROM documents d WHERE d.id = s.document_id AND d.deleted_at IS NULL '
      'AND ${access.visibleSql(u, 'document', 'd')})${u.isSuperuser ? '' : ' AND (s.owner IS NULL OR s.owner = ${u.id})'}';

  Response _list(Request request) {
    final user = _user(request);
    access.require(user, 'view', 'sharelink');
    final rows = db.select('SELECT * FROM share_links s WHERE ${_visible(user)} ORDER BY created DESC');
    return paginated(
      request,
      (limit, offset) => [for (final r in rows.skip(offset).take(limit)) _serialize(r)],
      allIds: [for (final r in rows) r['id'] as int],
    );
  }

  Response _forDocument(Request request) {
    final user = _user(request);
    access.require(user, 'view', 'sharelink');
    final rows = db.select(
      'SELECT * FROM share_links s WHERE s.document_id = ? AND ${_visible(user)} ORDER BY created DESC',
      [int.parse(request.params['id']!)],
    );
    return json([for (final r in rows) _serialize(r)]);
  }

  Future<Response> _create(Request request) async {
    final user = _user(request);
    access.require(user, 'add', 'sharelink');
    final body = await readBody(request);
    final docId = asInt(body['document']) ?? (throw ApiError.badRequest({'document': ['This field is required.']}));
    final doc = db.select(
      'SELECT id, archive_path FROM documents d WHERE d.id = ? AND d.deleted_at IS NULL '
      'AND ${access.visibleSql(user, 'document', 'd')}',
      [docId],
    ).firstOrNull;
    if (doc == null) throw ApiError.badRequest({'document': ['Invalid document.']});
    var version = '${body['file_version'] ?? 'archive'}';
    if (version != 'original' && version != 'archive') {
      throw ApiError.badRequest({'file_version': ['Expected "archive" or "original".']});
    }
    if (version == 'archive' && doc['archive_path'] == null) version = 'original';
    final expiration = body['expiration'];
    if (expiration != null && DateTime.tryParse('$expiration') == null) {
      throw ApiError.badRequest({'expiration': ['Invalid date.']});
    }
    db.execute(
      'INSERT INTO share_links (slug, document_id, expiration, file_version, created, owner) VALUES (?, ?, ?, ?, ?, ?)',
      [_slug(), docId, expiration?.toString(), version, nowIso(), user.id],
    );
    return json(_serialize(db.select('SELECT * FROM share_links WHERE id = ?', [db.lastInsertRowId]).first), status: 201);
  }

  Row _require(Request request) {
    final user = _user(request);
    return db.select('SELECT * FROM share_links s WHERE s.id = ? AND ${_visible(user)}', [int.parse(request.params['id']!)])
            .firstOrNull ??
        (throw ApiError(404, 'Not found.'));
  }

  Response _get(Request request) {
    access.require(_user(request), 'view', 'sharelink');
    return json(_serialize(_require(request)));
  }

  Response _delete(Request request) {
    access.require(_user(request), 'delete', 'sharelink');
    db.execute('DELETE FROM share_links WHERE id = ?', [_require(request)['id']]);
    return Response(204);
  }

  /// Öffentlich, ohne Anmeldung.
  Future<Response> _download(Request request) async {
    final row = db.select(
      'SELECT s.*, d.original_path, d.archive_path, d.original_filename, d.mime_type FROM share_links s '
      'JOIN documents d ON d.id = s.document_id WHERE s.slug = ? AND d.deleted_at IS NULL',
      [request.params['slug']],
    ).firstOrNull;
    final expiration = row?['expiration'] == null ? null : DateTime.tryParse(row!['expiration'] as String);
    if (row == null || (expiration != null && expiration.isBefore(DateTime.now()))) {
      return Response.notFound('Dieser Link ist ungültig oder abgelaufen.');
    }
    final original = row['original_filename'] as String;
    if (row['file_version'] == 'archive' && row['archive_path'] != null) {
      final f = await store.get(row['archive_path'] as String);
      if (f != null) return sendFile(f, 'application/pdf', filename: '${p.basenameWithoutExtension(original)}.pdf', inline: true);
    }
    final f = await store.get(row['original_path'] as String);
    if (f == null) return Response.notFound('Datei nicht gefunden.');
    return sendFile(f, row['mime_type'] as String, filename: original, inline: true);
  }

  void mount(void Function(String method, String path, Function handler) route) {
    route('GET', '/api/share_links/', _list);
    route('POST', '/api/share_links/', _create);
    route('GET', '/api/share_links/<id|[0-9]+>/', _get);
    route('DELETE', '/api/share_links/<id|[0-9]+>/', _delete);
    route('GET', '/api/documents/<id|[0-9]+>/share_links/', _forDocument);
    route('GET', '/share/<slug>/', _download);
  }
}
