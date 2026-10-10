import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../access.dart';
import '../auth.dart';
import 'http_utils.dart';

/// Integrations-Token (`/api/integration_tokens/`, PaperBuddy-Erweiterung):
/// Schlüssel für andere Programme wie Famio, die nur Dokumente mit einem Tag
/// lesen dürfen, samt deren Fristen. Ein Token sieht höchstens, was sein
/// Ersteller sieht; der Schlüssel erscheint nur beim Anlegen.
class IntegrationTokensResource {
  IntegrationTokensResource(this.db, this.auth, this.access);
  final Database db;
  final AuthService auth;
  final Access access;

  /// Was ein Integrations-Token abrufen darf (nur lesend).
  static const allowedPaths = [
    'api/documents/',
    'api/tags/',
    'api/correspondents/',
    'api/document_types/',
    'api/storage_paths/',
    'api/custom_fields/',
    'api/reminders/',
  ];

  /// Auch innerhalb erlaubter Bereiche gesperrt: wer was angesehen hat und
  /// Freigabelinks.
  static const _blocked = ['/access_log', '/share_links', '/history'];

  /// `null`, wenn erlaubt, sonst die Antwort mit dem Grund.
  static Response? check(Request request, User user) {
    if (user.scope == null) return null;
    final path = request.url.path;
    final readable = request.method == 'GET' || request.method == 'HEAD';
    final allowed = path == 'api' || path == 'api/' ||
        (allowedPaths.any((p) => path == p.substring(0, p.length - 1) || path.startsWith(p)) &&
            !_blocked.any(path.contains));
    if (readable && allowed) return null;
    return json({'detail': 'This integration token may only read documents with its tag.'}, status: 403);
  }

  User _user(Request r) {
    final user = r.context['user'] as User;
    if (user.scope != null) throw Access.forbidden();
    return user;
  }

  Map<String, Object?> _serialize(Row r) => {
    'id': r['id'],
    'name': r['name'],
    'tag': r['tag_id'],
    'tag_name': r['tag_name'],
    'owner': r['user_id'],
    'created': r['created'],
    'last_used': r['last_used'],
  };

  static const _select =
      'SELECT t.*, g.name AS tag_name FROM integration_tokens t LEFT JOIN tags g ON g.id = t.tag_id';

  /// Eigene Token; Administratoren sehen alle.
  Response list(Request request) {
    final user = _user(request);
    final rows = user.isSuperuser
        ? db.select('$_select ORDER BY t.created DESC')
        : db.select('$_select WHERE t.user_id = ? ORDER BY t.created DESC', [user.id]);
    return json([for (final r in rows) _serialize(r)]);
  }

  Future<Response> create(Request request) async {
    final user = _user(request);
    final body = await readBody(request);
    final name = '${body['name'] ?? ''}'.trim();
    final tag = asInt(body['tag']);
    if (name.isEmpty || tag == null) {
      throw ApiError.badRequest({
        if (name.isEmpty) 'name': ['This field is required.'],
        if (tag == null) 'tag': ['This field is required.'],
      });
    }
    if (db.select('SELECT 1 FROM tags x WHERE x.id = ? AND ${access.visibleSql(user, 'tag', 'x')}', [tag]).isEmpty) {
      throw ApiError.badRequest({'tag': ['Unknown tag.']});
    }
    final (id, key) = auth.createIntegrationToken(user, name, tag);
    return json({..._serialize(db.select('$_select WHERE t.id = ?', [id]).first), 'token': key}, status: 201);
  }

  Response delete(Request request) {
    final user = _user(request);
    final id = int.parse(request.params['id']!);
    final row = db.select('SELECT user_id FROM integration_tokens WHERE id = ?', [id]).firstOrNull;
    if (row == null || (row['user_id'] != user.id && !user.isSuperuser)) throw ApiError(404, 'Not found.');
    db.execute('DELETE FROM integration_tokens WHERE id = ?', [id]);
    return Response(204);
  }

  void mount(void Function(String method, String path, Function handler) route) {
    route('GET', '/api/integration_tokens/', list);
    route('POST', '/api/integration_tokens/', create);
    route('DELETE', '/api/integration_tokens/<id|[0-9]+>/', delete);
  }
}
