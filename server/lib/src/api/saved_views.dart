import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../access.dart';
import '../auth.dart';
import 'http_utils.dart';

/// `/api/saved_views/`: Filterregeln werden gespeichert, ausgewertet werden
/// sie wie in Paperless-ngx vom Client.
class SavedViewsResource {
  SavedViewsResource(this.db, this.access);
  final Database db;
  final Access access;
  static const _model = 'savedview';

  Row? _row(User user, int id) => db.select(
        'SELECT * FROM saved_views x WHERE id = ? AND ${access.visibleSql(user, _model, 'x')}',
        [id],
      ).firstOrNull;

  Map<String, dynamic> serialize(Row r, User user, {bool fullPerms = false}) {
    final id = r['id'] as int;
    final owner = r['owner'] as int?;
    return {
      'id': id,
      'name': r['name'],
      'show_on_dashboard': r['show_on_dashboard'] == 1,
      'show_in_sidebar': r['show_in_sidebar'] == 1,
      'sort_field': r['sort_field'],
      'sort_reverse': r['sort_reverse'] == 1,
      'filter_rules': jsonDecode(r['filter_rules'] as String),
      'page_size': r['page_size'],
      'display_mode': r['display_mode'],
      'display_fields': r['display_fields'] == null ? null : jsonDecode(r['display_fields'] as String),
      'owner': owner,
      'user_can_change': access.canChange(user, _model, id, owner),
      if (fullPerms) 'permissions': access.permissionsJson(_model, id),
    };
  }

  Map<String, Object?> _values(Map<String, dynamic> body, {required bool partial}) {
    final out = <String, Object?>{};
    void put(String key, Object? Function(Object?) convert) {
      if (body.containsKey(key)) out[key] = convert(body[key]);
    }

    put('name', (v) => v?.toString().trim());
    put('show_on_dashboard', (v) => asBool(v) ? 1 : 0);
    put('show_in_sidebar', (v) => asBool(v) ? 1 : 0);
    put('sort_field', (v) => v?.toString());
    put('sort_reverse', (v) => asBool(v) ? 1 : 0);
    put('page_size', asInt);
    put('display_mode', (v) => v?.toString());
    put('display_fields', (v) => v == null ? null : jsonEncode(v));
    put('owner', asInt);
    if (body.containsKey('filter_rules')) {
      final rules = body['filter_rules'];
      if (rules is! List) throw ApiError.badRequest({'filter_rules': ['Expected a list.']});
      out['filter_rules'] = jsonEncode([
        for (final r in rules)
          if (r is Map) {'rule_type': asInt(r['rule_type']), 'value': r['value']?.toString()},
      ]);
    }
    if (!partial && ((out['name'] as String?) ?? '').isEmpty) {
      throw ApiError.badRequest({'name': ['This field is required.']});
    }
    return out;
  }

  Response list(Request request) {
    final user = request.context['user'] as User;
    access.require(user, 'view', _model);
    final rows = db.select(
      'SELECT * FROM saved_views x WHERE ${access.visibleSql(user, _model, 'x')} ORDER BY name COLLATE NOCASE',
    );
    final fullPerms = asBool(request.url.queryParameters['full_perms']);
    return paginated(
      request,
      (limit, offset) => [for (final r in rows.skip(offset).take(limit)) serialize(r, user, fullPerms: fullPerms)],
      allIds: [for (final r in rows) r['id'] as int],
      defaultPageSize: 100,
    );
  }

  Response get(Request request) {
    final user = request.context['user'] as User;
    access.require(user, 'view', _model);
    final row = _row(user, int.parse(request.params['id']!)) ?? (throw ApiError(404, 'Not found.'));
    return json(serialize(row, user, fullPerms: asBool(request.url.queryParameters['full_perms'])));
  }

  Future<Response> create(Request request) async {
    final user = request.context['user'] as User;
    access.require(user, 'add', _model);
    final body = await readBody(request);
    final values = _values(body, partial: false)..putIfAbsent('owner', () => user.id);
    final cols = values.keys.toList();
    db.execute(
      'INSERT INTO saved_views (${cols.join(', ')}) VALUES (${List.filled(cols.length, '?').join(', ')})',
      [for (final c in cols) values[c]],
    );
    final id = db.lastInsertRowId;
    access.setPermissions(_model, id, body['set_permissions']);
    return json(serialize(_row(user, id)!, user), status: 201);
  }

  Future<Response> update(Request request, {required bool partial}) async {
    final user = request.context['user'] as User;
    access.require(user, 'change', _model);
    final row = _row(user, int.parse(request.params['id']!)) ?? (throw ApiError(404, 'Not found.'));
    final id = row['id'] as int;
    final owner = row['owner'] as int?;
    if (!access.canChange(user, _model, id, owner)) throw Access.forbidden();
    final body = await readBody(request);
    final values = _values(body, partial: partial);
    final isOwner = user.isSuperuser || owner == null || owner == user.id;
    if (!isOwner) values.remove('owner');
    if (values.isNotEmpty) {
      final cols = values.keys.toList();
      db.execute(
        'UPDATE saved_views SET ${cols.map((c) => '$c = ?').join(', ')} WHERE id = ?',
        [for (final c in cols) values[c], id],
      );
    }
    if (isOwner && body.containsKey('set_permissions')) {
      access.setPermissions(_model, id, body['set_permissions']);
    }
    return json(serialize(_row(user, id)!, user));
  }

  Response delete(Request request) {
    final user = request.context['user'] as User;
    access.require(user, 'delete', _model);
    final row = _row(user, int.parse(request.params['id']!)) ?? (throw ApiError(404, 'Not found.'));
    if (!access.canChange(user, _model, row['id'] as int, row['owner'] as int?)) throw Access.forbidden();
    db.execute('DELETE FROM saved_views WHERE id = ?', [row['id']]);
    access.forgetObject(_model, row['id'] as int);
    return Response(204);
  }

  void mount(void Function(String method, String path, Function handler) route) {
    route('GET', '/api/saved_views/', list);
    route('POST', '/api/saved_views/', create);
    route('GET', '/api/saved_views/<id|[0-9]+>/', get);
    route('PUT', '/api/saved_views/<id|[0-9]+>/', (Request r) => update(r, partial: false));
    route('PATCH', '/api/saved_views/<id|[0-9]+>/', (Request r) => update(r, partial: true));
    route('DELETE', '/api/saved_views/<id|[0-9]+>/', delete);
  }
}
