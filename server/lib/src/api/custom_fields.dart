import 'dart:convert';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../access.dart';
import '../auth.dart';
import '../db.dart';
import 'http_utils.dart';

/// Datentypen wie in Paperless-ngx.
const customFieldTypes = {
  'string',
  'longtext',
  'url',
  'date',
  'boolean',
  'integer',
  'float',
  'monetary',
  'documentlink',
  'select',
};

/// `/api/custom_fields/` und die Werte der Felder an Dokumenten.
class CustomFieldsResource {
  CustomFieldsResource(this.db, this.access);
  final Database db;
  final Access access;
  static final _random = Random.secure();

  Row? _row(int id) => db.select('SELECT * FROM custom_fields WHERE id = ?', [id]).firstOrNull;

  Map<String, dynamic> serialize(Row r, User user) => {
        'id': r['id'],
        'name': r['name'],
        'data_type': r['data_type'],
        'extra_data': jsonDecode(r['extra_data'] as String),
        'document_count': db.select(
          'SELECT COUNT(*) AS c FROM document_custom_fields f JOIN documents d ON d.id = f.document_id '
          'WHERE f.field_id = ? AND d.deleted_at IS NULL AND ${access.visibleSql(user, 'document', 'd')}',
          [r['id']],
        ).first['c'],
      };

  Response list(Request request) {
    final user = request.context['user'] as User;
    access.require(user, 'view', 'customfield');
    final q = request.url.queryParameters;
    final where = <String>['1 = 1'];
    final args = <Object?>[];
    final name = q['name__icontains'];
    if (name != null && name.isNotEmpty) {
      where.add('name LIKE ?');
      args.add('%$name%');
    }
    final ids = asIntList(q['id__in']);
    if (ids.isNotEmpty) where.add('id IN (${ids.join(',')})');
    final desc = (q['ordering'] ?? '').startsWith('-');
    final rows = db.select(
      'SELECT * FROM custom_fields WHERE ${where.join(' AND ')} '
      'ORDER BY name COLLATE NOCASE ${desc ? 'DESC' : 'ASC'}',
      args,
    );
    return paginated(
      request,
      (limit, offset) => [for (final r in rows.skip(offset).take(limit)) serialize(r, user)],
      allIds: [for (final r in rows) r['id'] as int],
      defaultPageSize: 100,
    );
  }

  Response get(Request request) {
    final user = request.context['user'] as User;
    access.require(user, 'view', 'customfield');
    final row = _row(int.parse(request.params['id']!)) ?? (throw ApiError(404, 'Not found.'));
    return json(serialize(row, user));
  }

  /// Auswahloptionen: ältere Clients schicken nur Texte, neuere `{id, label}`.
  Map<String, dynamic> _extraData(String type, Object? raw, [Map<String, dynamic>? previous]) {
    final extra = <String, dynamic>{...?previous, if (raw is Map) ...raw.cast<String, dynamic>()};
    if (type == 'select') {
      final options = extra['select_options'];
      extra['select_options'] = [
        if (options is List)
          for (final o in options)
            if (o is Map)
              {'id': o['id']?.toString() ?? _optionId(), 'label': '${o['label'] ?? ''}'}
            else
              {'id': _optionId(), 'label': '$o'},
      ];
    }
    if (type == 'monetary') extra.putIfAbsent('default_currency', () => null);
    return extra;
  }

  static String _optionId() =>
      List.generate(16, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)]).join();

  Future<Response> create(Request request) async {
    final user = request.context['user'] as User;
    access.require(user, 'add', 'customfield');
    final body = await readBody(request);
    final name = body['name']?.toString().trim() ?? '';
    final type = body['data_type']?.toString() ?? '';
    if (name.isEmpty) throw ApiError.badRequest({'name': ['This field is required.']});
    if (!customFieldTypes.contains(type)) {
      throw ApiError.badRequest({'data_type': ['"$type" is not a valid choice.']});
    }
    try {
      db.execute(
        'INSERT INTO custom_fields (name, data_type, extra_data, created) VALUES (?, ?, ?, ?)',
        [name, type, jsonEncode(_extraData(type, body['extra_data'])), nowIso()],
      );
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 2067) {
        throw ApiError.badRequest({'name': ['Custom field with this name already exists.']});
      }
      rethrow;
    }
    return json(serialize(_row(db.lastInsertRowId)!, user), status: 201);
  }

  Future<Response> update(Request request) async {
    final user = request.context['user'] as User;
    access.require(user, 'change', 'customfield');
    final row = _row(int.parse(request.params['id']!)) ?? (throw ApiError(404, 'Not found.'));
    final body = await readBody(request);
    final type = row['data_type'] as String;
    if (body.containsKey('data_type') && body['data_type'] != type) {
      throw ApiError.badRequest({'data_type': ['The data type cannot be changed.']});
    }
    final name = body['name']?.toString().trim();
    try {
      db.execute(
        'UPDATE custom_fields SET name = COALESCE(?, name), extra_data = ? WHERE id = ?',
        [
          (name?.isEmpty ?? true) ? null : name,
          jsonEncode(body.containsKey('extra_data')
              ? _extraData(type, body['extra_data'])
              : jsonDecode(row['extra_data'] as String)),
          row['id'],
        ],
      );
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 2067) {
        throw ApiError.badRequest({'name': ['Custom field with this name already exists.']});
      }
      rethrow;
    }
    return json(serialize(_row(row['id'] as int)!, user));
  }

  Response delete(Request request) {
    final user = request.context['user'] as User;
    access.require(user, 'delete', 'customfield');
    final id = int.parse(request.params['id']!);
    if (_row(id) == null) throw ApiError(404, 'Not found.');
    db.execute('DELETE FROM custom_fields WHERE id = ?', [id]);
    return Response(204);
  }

  void mount(void Function(String method, String path, Function handler) route) {
    route('GET', '/api/custom_fields/', list);
    route('POST', '/api/custom_fields/', create);
    route('GET', '/api/custom_fields/<id|[0-9]+>/', get);
    route('PUT', '/api/custom_fields/<id|[0-9]+>/', update);
    route('PATCH', '/api/custom_fields/<id|[0-9]+>/', update);
    route('DELETE', '/api/custom_fields/<id|[0-9]+>/', delete);
  }

  // ---------------------------------------------------------------------------
  // Werte an Dokumenten

  List<Map<String, dynamic>> valuesOf(int documentId) => [
        for (final r in db.select(
          'SELECT field_id, value FROM document_custom_fields WHERE document_id = ? ORDER BY id',
          [documentId],
        ))
          {'field': r['field_id'], 'value': r['value'] == null ? null : jsonDecode(r['value'] as String)},
      ];

  /// Prüft und normalisiert einen Wert passend zum Feldtyp.
  Object? validate(Row field, Object? value) {
    if (value == null) return null;
    final type = field['data_type'] as String;
    Never bad(String msg) => throw ApiError.badRequest({'custom_fields': [msg]});
    switch (type) {
      case 'string':
        final s = '$value';
        if (s.length > 128) bad('Ensure this field has no more than 128 characters.');
        return s;
      case 'longtext':
        return '$value';
      case 'url':
        final s = '$value'.trim();
        if (s.isEmpty) return null;
        final uri = Uri.tryParse(s);
        if (uri == null || !uri.hasScheme) bad('Enter a valid URL.');
        return s;
      case 'date':
        return asDate(value);
      case 'boolean':
        return value is bool ? value : asBool(value);
      case 'integer':
        if (value is int) return value;
        return int.tryParse('$value') ?? bad('A valid integer is required.');
      case 'float':
        if (value is num) return value.toDouble();
        return double.tryParse('$value') ?? bad('A valid number is required.');
      case 'monetary':
        final s = '$value'.trim();
        if (s.isEmpty) return null;
        if (!RegExp(r'^([A-Z]{3})?-?\d+(\.\d{1,2})?$').hasMatch(s)) {
          bad('Monetary value must be a number with up to two decimals, optionally prefixed with a currency code.');
        }
        return s;
      case 'documentlink':
        return asIntList(value);
      case 'select':
        final options = ((jsonDecode(field['extra_data'] as String) as Map)['select_options'] as List?) ?? [];
        final ids = [for (final o in options) (o as Map)['id'].toString()];
        if (value is int && value >= 0 && value < ids.length) return ids[value];
        if (ids.contains('$value')) return '$value';
        bad('Invalid select option.');
    }
    return value;
  }

  /// Ersetzt alle Feldwerte eines Dokuments. Akzeptiert die Listenform
  /// `[{"field": 1, "value": …}]` und die Kurzform `{"1": …}`.
  void replaceValues(int documentId, Object? spec) {
    db.execute('DELETE FROM document_custom_fields WHERE document_id = ?', [documentId]);
    _upsert(documentId, _entries(spec));
  }

  /// Ergänzt bzw. überschreibt einzelne Feldwerte (Bulk-Edit).
  void addValues(int documentId, Object? spec) => _upsert(documentId, _entries(spec));

  void removeFields(int documentId, List<int> fieldIds) {
    if (fieldIds.isEmpty) return;
    db.execute(
      'DELETE FROM document_custom_fields WHERE document_id = ? AND field_id IN (${fieldIds.join(',')})',
      [documentId],
    );
  }

  List<(int, Object?)> _entries(Object? spec) {
    if (spec is Map) {
      return [for (final e in spec.entries) (asInt(e.key)!, e.value)];
    }
    if (spec is List) {
      return [
        for (final e in spec)
          if (e is Map) (asInt(e['field'])!, e['value']) else (asInt(e)!, null),
      ];
    }
    return const [];
  }

  void _upsert(int documentId, List<(int, Object?)> entries) {
    for (final (fieldId, raw) in entries) {
      final field = _row(fieldId) ??
          (throw ApiError.badRequest({'custom_fields': ['Custom field $fieldId does not exist.']}));
      final value = validate(field, raw);
      db.execute(
        'INSERT INTO document_custom_fields (document_id, field_id, value) VALUES (?, ?, ?) '
        'ON CONFLICT(document_id, field_id) DO UPDATE SET value = excluded.value',
        [documentId, fieldId, value == null ? null : jsonEncode(value)],
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Filter

  /// `custom_field_query` aus Paperless-ngx, z. B.
  /// `["AND", [["Betrag", "gt", 100], ["Bezahlt", "exact", true]]]`.
  String queryToSql(Object? query, List<Object?> args) {
    if (query is! List || query.isEmpty) throw ApiError.badRequest({'custom_field_query': ['Invalid query.']});
    final head = query.first;
    if (head is String && (head.toUpperCase() == 'AND' || head.toUpperCase() == 'OR') && query.length == 2) {
      final parts = [for (final q in query[1] as List) queryToSql(q, args)];
      if (parts.isEmpty) return '1 = 1';
      return '(${parts.join(' ${head.toUpperCase()} ')})';
    }
    if (head is String && head.toUpperCase() == 'NOT' && query.length == 2) {
      return 'NOT ${queryToSql(query[1], args)}';
    }
    if (query.length != 3) throw ApiError.badRequest({'custom_field_query': ['Invalid query.']});
    final fieldRef = query[0];
    final op = '${query[1]}';
    final value = query[2];
    final field = fieldRef is int
        ? _row(fieldRef)
        : (int.tryParse('$fieldRef') != null
            ? _row(int.parse('$fieldRef'))
            : db.select('SELECT * FROM custom_fields WHERE name = ?', ['$fieldRef']).firstOrNull);
    if (field == null) throw ApiError.badRequest({'custom_field_query': ['Unknown field: $fieldRef']});
    final fid = field['id'] as int;
    const v = "json_extract(f.value, '\$')";
    String exists(String cond) =>
        'EXISTS (SELECT 1 FROM document_custom_fields f WHERE f.document_id = d.id AND f.field_id = $fid AND $cond)';
    switch (op) {
      case 'exists':
        return asBool(value) ? exists('1 = 1') : 'NOT ${exists('1 = 1')}';
      case 'isnull':
        return asBool(value) ? exists('f.value IS NULL OR $v IS NULL') : exists('$v IS NOT NULL');
      case 'exact':
        args.add(_sqlValue(field, value));
        return exists('$v = ?');
      case 'in':
        final list = value is List ? value : [value];
        args.addAll(list.map((e) => _sqlValue(field, e)));
        return exists('$v IN (${List.filled(list.length, '?').join(',')})');
      case 'icontains' || 'istartswith' || 'iendswith':
        args.add(switch (op) { 'icontains' => '%$value%', 'istartswith' => '$value%', _ => '%$value' });
        return exists('CAST($v AS TEXT) LIKE ?');
      case 'gt' || 'gte' || 'lt' || 'lte':
        args.add(_sqlValue(field, value));
        final sql = const {'gt': '>', 'gte': '>=', 'lt': '<', 'lte': '<='}[op];
        return exists('${_numeric(field, v)} $sql ${_numeric(field, '?')}');
      case 'range':
        final r = value as List;
        args.addAll([_sqlValue(field, r[0]), _sqlValue(field, r[1])]);
        return exists('${_numeric(field, v)} BETWEEN ${_numeric(field, '?')} AND ${_numeric(field, '?')}');
      case 'contains':
        final ids = asIntList(value);
        return [
          for (final id in ids) exists("EXISTS (SELECT 1 FROM json_each(f.value) WHERE json_each.value = $id)"),
        ].join(' AND ');
    }
    throw ApiError.badRequest({'custom_field_query': ['Unsupported operator: $op']});
  }

  Object? _sqlValue(Row field, Object? value) => switch (value) {
        bool b => b ? 1 : 0,
        _ => value,
      };

  /// Geldbeträge werden als Text mit optionaler Währung gespeichert.
  String _numeric(Row field, String expr) => field['data_type'] == 'monetary'
      ? "CAST(ltrim($expr, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') AS REAL)"
      : expr;
}
