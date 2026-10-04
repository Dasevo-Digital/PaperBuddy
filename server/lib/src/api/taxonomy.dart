import 'dart:math' as math;

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import 'http_utils.dart';

/// Gemeinsame CRUD-Logik für Tags, Korrespondenten, Dokumenttypen und
/// Speicherpfade.
class TaxonomyResource {
  TaxonomyResource({
    required this.db,
    required this.table,
    required this.documentCountSql,
    this.extraFields = const {},
    this.extraSerializer,
  });

  final Database db;
  final String table;

  /// SQL-Ausdruck mit Platzhalter `x.id`.
  final String documentCountSql;

  /// Zusätzliche schreibbare Felder: Feldname → Umwandlung des Eingabewerts.
  final Map<String, Object? Function(Object?)> extraFields;
  final void Function(Row row, Map<String, dynamic> out)? extraSerializer;

  static final _commonFields = <String, Object? Function(Object?)>{
    'name': (v) => v?.toString().trim(),
    'match': (v) => v?.toString() ?? '',
    'matching_algorithm': (v) => asInt(v) ?? 0,
    'is_insensitive': (v) => asBool(v) ? 1 : 0,
    'owner': asInt,
  };

  Map<String, Object? Function(Object?)> get _writable => {
    ..._commonFields,
    ...extraFields,
  };

  Map<String, dynamic> serialize(Row row, User user, {bool fullPerms = false}) {
    final out = <String, dynamic>{
      'id': row['id'],
      'slug': slugify(row['name'] as String),
      'name': row['name'],
      'match': row['match'],
      'matching_algorithm': row['matching_algorithm'],
      'is_insensitive': row['is_insensitive'] == 1,
      'document_count': row['document_count'],
      'owner': row['owner'],
      'user_can_change': true,
    };
    extraSerializer?.call(row, out);
    if (fullPerms) out['permissions'] = emptyPermissions;
    return out;
  }

  String get _select =>
      'SELECT x.*, ($documentCountSql) AS document_count FROM $table x';

  static const _orderings = {
    'id': 'x.id',
    'name': 'x.name COLLATE NOCASE',
    'match': 'x.match',
    'matching_algorithm': 'x.matching_algorithm',
    'document_count': 'document_count',
  };

  Row? _byId(int id) => db.select('$_select WHERE x.id = ?', [id]).firstOrNull;

  Response list(Request request) {
    final user = request.context['user'] as User;
    final q = request.url.queryParameters;
    final where = <String>[];
    final args = <Object?>[];
    void filter(String param, String sql, [Object? Function(String)? map]) {
      final v = q[param];
      if (v == null || v.isEmpty) return;
      where.add(sql);
      args.add(map == null ? v : map(v));
    }

    filter(
      'name__icontains',
      'x.name LIKE ? ESCAPE \'\\\'',
      (v) => '%${_like(v)}%',
    );
    filter(
      'name__istartswith',
      'x.name LIKE ? ESCAPE \'\\\'',
      (v) => '${_like(v)}%',
    );
    filter(
      'name__iendswith',
      'x.name LIKE ? ESCAPE \'\\\'',
      (v) => '%${_like(v)}',
    );
    filter('name__iexact', 'x.name = ? COLLATE NOCASE');
    final ids = asIntList(q['id__in']);
    if (ids.isNotEmpty) where.add('x.id IN (${ids.join(',')})');

    final whereSql = where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';
    var ordering = q['ordering'] ?? 'name';
    final desc = ordering.startsWith('-');
    ordering = ordering.replaceFirst('-', '');
    final orderSql =
        ' ORDER BY ${_orderings[ordering] ?? _orderings['name']} ${desc ? 'DESC' : 'ASC'}, x.id';

    final rows = db.select('$_select$whereSql$orderSql', args);
    final fullPerms = asBool(q['full_perms']);
    return paginated(
      request,
      (limit, offset) => [
        for (final row in rows.skip(offset).take(limit))
          serialize(row, user, fullPerms: fullPerms),
      ],
      allIds: [for (final row in rows) row['id'] as int],
      defaultPageSize: 100,
    );
  }

  Response get(Request request) {
    final row = _byId(int.parse(request.params['id']!));
    if (row == null) throw ApiError(404, 'Not found.');
    return json(
      serialize(
        row,
        request.context['user'] as User,
        fullPerms: asBool(request.url.queryParameters['full_perms']),
      ),
    );
  }

  Future<Response> create(Request request) async {
    final user = request.context['user'] as User;
    final body = await readBody(request);
    final values = _parse(body, partial: false);
    values.putIfAbsent('owner', () => user.id);
    final cols = values.keys.toList();
    _guardUnique(
      () => db.execute(
        'INSERT INTO $table (${cols.join(', ')}) '
        'VALUES (${List.filled(cols.length, '?').join(', ')})',
        [for (final c in cols) values[c]],
      ),
    );
    return json(serialize(_byId(db.lastInsertRowId)!, user), status: 201);
  }

  Future<Response> update(Request request, {required bool partial}) async {
    final id = int.parse(request.params['id']!);
    if (_byId(id) == null) throw ApiError(404, 'Not found.');
    final values = _parse(await readBody(request), partial: partial);
    if (values.isNotEmpty) {
      final cols = values.keys.toList();
      _guardUnique(
        () => db.execute(
          'UPDATE $table SET ${cols.map((c) => '$c = ?').join(', ')} WHERE id = ?',
          [for (final c in cols) values[c], id],
        ),
      );
    }
    return json(serialize(_byId(id)!, request.context['user'] as User));
  }

  Response delete(Request request) {
    final id = int.parse(request.params['id']!);
    if (_byId(id) == null) throw ApiError(404, 'Not found.');
    db.execute('DELETE FROM $table WHERE id = ?', [id]);
    return Response(204);
  }

  Map<String, Object?> _parse(
    Map<String, dynamic> body, {
    required bool partial,
  }) {
    final values = <String, Object?>{};
    _writable.forEach((field, convert) {
      if (body.containsKey(field)) values[field] = convert(body[field]);
    });
    if (!partial && (values['name'] as String?)?.isNotEmpty != true) {
      throw ApiError.badRequest({
        'name': ['This field is required.'],
      });
    }
    if (values.containsKey('name') && (values['name'] as String?)!.isEmpty) {
      throw ApiError.badRequest({
        'name': ['This field may not be blank.'],
      });
    }
    return values;
  }

  void _guardUnique(void Function() action) {
    try {
      action();
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 2067) {
        throw ApiError.badRequest({
          'name': ['Object with this name already exists.'],
        });
      }
      rethrow;
    }
  }

  void mount(
    Router router,
    String path,
    void Function(String method, String path, Function handler) route,
  ) {
    route('GET', '/api/$path/', list);
    route('POST', '/api/$path/', create);
    route('GET', '/api/$path/<id|[0-9]+>/', get);
    route(
      'PUT',
      '/api/$path/<id|[0-9]+>/',
      (Request r) => update(r, partial: false),
    );
    route(
      'PATCH',
      '/api/$path/<id|[0-9]+>/',
      (Request r) => update(r, partial: true),
    );
    route('DELETE', '/api/$path/<id|[0-9]+>/', delete);
  }
}

const emptyPermissions = {
  'view': {'users': <int>[], 'groups': <int>[]},
  'change': {'users': <int>[], 'groups': <int>[]},
};

String _like(String v) =>
    v.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');

/// Textfarbe passend zur Hintergrundfarbe, wie Paperless-ngx sie berechnet.
String textColorFor(String hex) {
  final h = hex.replaceFirst('#', '');
  if (h.length != 6) return '#000000';
  double channel(int i) {
    final c = int.parse(h.substring(i, i + 2), radix: 16) / 255;
    return c <= 0.03928
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  final luminance =
      0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
  return luminance > 0.53 ? '#000000' : '#ffffff';
}
