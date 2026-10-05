import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../access.dart';
import '../auth.dart';
import '../history.dart';
import '../processing/consumer.dart';
import '../processing/pdf_ops.dart';
import '../processing/tools.dart';
import '../storage.dart';
import '../trash.dart';
import 'custom_fields.dart';
import 'saved_views.dart';
import 'share_links.dart';
import 'users.dart';
import 'documents.dart';
import 'http_utils.dart';
import 'taxonomy.dart';


final _log = Logger('api');

/// REST-API, kompatibel zu Paperless-ngx, damit vorhandene Apps
/// (Swift Paperless, Paperless Mobile …) direkt funktionieren.
class PaperlessApi {
  PaperlessApi({
    required this.db,
    required this.auth,
    required this.access,
    required this.store,
    required this.consumer,
    required this.tools,
    required this.trash,
    required this.customFields,
    this.pdf,
    this.history,
    this.extraRoutes = const [],
    this.onDocumentUpdated,
    this.onLabelUpdated,
    this.oauthUrls,
    this.corsOrigins = const [],
  });

  final Database db;
  final AuthService auth;
  final Access access;
  final BlobStore store;
  final Consumer consumer;
  final ExternalTools tools;
  final Trash trash;
  final List<String> corsOrigins;

  /// Weitere Ressourcen (Workflows, Mail, Scanner …) hängen sich hier ein.
  final List<void Function(void Function(String method, String path, Function handler) route)> extraRoutes;
  final Future<void> Function(int documentId)? onDocumentUpdated;

  /// Label geändert: `(tabelle, id)`.
  final Future<void> Function(String table, int id)? onLabelUpdated;

  /// OAuth-Anmelde-Links für `ui_settings` (Gmail/Outlook).
  final Map<String, String?> Function(User user)? oauthUrls;

  final CustomFieldsResource customFields;
  final PdfOperations? pdf;
  final History? history;
  final _taxonomies = <String, TaxonomyResource>{};

  static const _public = {'api/token/', 'api/token', 'api/oauth/callback/', 'api/oauth/callback'};

  Handler get handler {
    final router = Router(
      notFoundHandler: (_) => ApiError(404, 'Not found.').toResponse(),
    );

    // Paperless verwendet abschließende Schrägstriche; manche Clients lassen
    // sie weg. Darum jede Route in beiden Varianten registrieren.
    void route(String method, String path, Function handler) {
      router.add(method, path, handler);
      router.add(method, path.substring(0, path.length - 1), handler);
    }

    route('POST', '/api/token/', _token);
    route('GET', '/api/', _root);
    route('GET', '/api/ui_settings/', _uiSettings);
    route('POST', '/api/ui_settings/', _saveUiSettings);
    route('GET', '/api/tasks/', _tasks);
    route('POST', '/api/tasks/acknowledge/', _acknowledgeTasks);
    route('GET', '/api/statistics/', _statistics);
    route(
      'GET',
      '/api/remote_version/',
      (Request r) => json({'version': PaperlessCompat.serverVersion, 'update_available': false}),
    );
    route('GET', '/api/status/', _status);
    route('GET', '/api/search/autocomplete/', _autocomplete);
    route('POST', '/api/bulk_edit_objects/', _bulkEditObjects);

    route('GET', '/api/tasks/<id|[0-9]+>/', _task);
    route('POST', '/api/acknowledge_tasks/', _acknowledgeTasks);
    route('GET', '/api/config/', _config);
    ShareLinksResource(db, access, store).mount(route);

    UsersResource(db, auth, access).mount(route);
    customFields.mount(route);
    SavedViewsResource(db, access).mount(route);
    DocumentsResource(
      db: db,
      store: store,
      consumer: consumer,
      access: access,
      customFields: customFields,
      trash: trash,
      pdf: pdf,
      history: history,
      onUpdated: onDocumentUpdated,
    ).mount(route);

    void taxonomy(
      String path,
      String table,
      String model,
      String countSql, {
      Map<String, Object? Function(Object?)> extraFields = const {},
      void Function(Row row, Map<String, dynamic> out, User user)? extraSerializer,
    }) {
      final resource = TaxonomyResource(
        db: db,
        access: access,
        table: table,
        model: model,
        documentCountSql: countSql,
        extraFields: extraFields,
        extraSerializer: extraSerializer,
        afterUpdate: onLabelUpdated == null ? null : (id) => onLabelUpdated!(table, id),
      )..mount(path, route);
      _taxonomies[path] = resource;
    }

    taxonomy(
      'tags',
      'tags',
      'tag',
      'SELECT COUNT(*) FROM document_tags dt JOIN documents d ON d.id = dt.document_id '
          'WHERE dt.tag_id = x.id AND {visible}',
      extraFields: {
        'color': (v) => v?.toString() ?? '#a6cee3',
        'is_inbox_tag': (v) => asBool(v) ? 1 : 0,
      },
      extraSerializer: (row, out, user) {
        final color = row['color'] as String;
        out['color'] = color;
        out['text_color'] = textColorFor(color);
        out['is_inbox_tag'] = row['is_inbox_tag'] == 1;
        out['parent'] = null;
        out['children'] = <Object>[];
      },
    );
    taxonomy(
      'correspondents',
      'correspondents',
      'correspondent',
      'SELECT COUNT(*) FROM documents d WHERE d.correspondent_id = x.id AND {visible}',
      extraSerializer: (row, out, user) {
        out['last_correspondence'] = db.select(
          'SELECT MAX(created) AS m FROM documents d WHERE d.correspondent_id = ? AND d.deleted_at IS NULL '
          'AND ${access.visibleSql(user, 'document', 'd')}',
          [row['id']],
        ).first['m'];
      },
    );
    taxonomy(
      'document_types',
      'document_types',
      'documenttype',
      'SELECT COUNT(*) FROM documents d WHERE d.document_type_id = x.id AND {visible}',
    );
    taxonomy(
      'storage_paths',
      'storage_paths',
      'storagepath',
      'SELECT COUNT(*) FROM documents d WHERE d.storage_path_id = x.id AND {visible}',
      extraFields: {'path': (v) => v?.toString() ?? ''},
      extraSerializer: (row, out, user) => out['path'] = row['path'],
    );

    for (final extra in extraRoutes) {
      extra(route);
    }

    return const Pipeline()
        .addMiddleware(_errors)
        .addMiddleware(_cors)
        .addMiddleware(_versionHeaders)
        .addMiddleware(_authenticate)
        .addHandler(router.call);
  }

  // ---------------------------------------------------------------------------
  // Middleware

  Handler _errors(Handler inner) => (request) async {
    try {
      return await inner(request);
    } on ApiError catch (e) {
      return e.toResponse();
    } catch (e, st) {
      _log.severe('${request.method} ${request.requestedUri}', e, st);
      return json({'detail': 'Internal server error.'}, status: 500);
    }
  };

  Handler _cors(Handler inner) => (request) async {
    final origin = request.headers['origin'];
    final allowed =
        origin != null &&
        (corsOrigins.contains('*') || corsOrigins.contains(origin));
    final headers = allowed
        ? {
            'access-control-allow-origin': origin,
            'access-control-allow-credentials': 'true',
            'access-control-allow-headers':
                'authorization, content-type, accept, x-requested-with',
            'access-control-allow-methods':
                'GET, POST, PUT, PATCH, DELETE, OPTIONS',
            'access-control-expose-headers': 'x-api-version, x-version',
            'vary': 'origin',
          }
        : const <String, String>{};
    if (request.method == 'OPTIONS') return Response.ok(null, headers: headers);
    final response = await inner(request);
    return response.change(headers: headers);
  };

  Handler _versionHeaders(Handler inner) => (request) async {
    final requested = RegExp(
      r'version=(\d+)',
    ).firstMatch(request.headers['accept'] ?? '');
    if (requested != null) {
      final v = int.parse(requested.group(1)!);
      if (v < PaperlessCompat.minApiVersion ||
          v > PaperlessCompat.maxApiVersion) {
        return json({
          'detail': 'Invalid version in "Accept" header.',
        }, status: 406);
      }
    }
    final response = await inner(request);
    return response.change(
      headers: {
        'x-api-version': '${PaperlessCompat.maxApiVersion}',
        'x-version': PaperlessCompat.serverVersion,
      },
    );
  };

  Handler _authenticate(Handler inner) => (request) async {
    if (_public.contains(request.url.path) ||
        !request.url.path.startsWith('api')) {
      return inner(request);
    }
    final user = await auth.userForAuthorizationHeader(
      request.headers['authorization'],
    );
    if (user == null) {
      return Response(
        401,
        body: jsonEncode({
          'detail': 'Authentication credentials were not provided.',
        }),
        headers: {
          'content-type': 'application/json',
          'www-authenticate': 'Token',
        },
      );
    }
    return inner(request.change(context: {'user': user}));
  };

  // ---------------------------------------------------------------------------
  // Endpunkte

  Future<Response> _token(Request request) async {
    final body = await readBody(request);
    final user = await auth.authenticate(
      body['username']?.toString() ?? '',
      body['password']?.toString() ?? '',
    );
    if (user == null) {
      throw ApiError.badRequest({
        'non_field_errors': ['Unable to log in with provided credentials.'],
      });
    }
    return json({'token': auth.tokenFor(user)});
  }

  Response _root(Request request) {
    final base = request.requestedUri.replace(path: '/api/', query: '');
    String link(String path) =>
        base.resolve(path).toString().replaceAll('?', '');
    return json({
      for (final name in [
        'correspondents',
        'document_types',
        'documents',
        'saved_views',
        'storage_paths',
        'tags',
        'tasks',
        'users',
        'groups',
        'custom_fields',
        'ui_settings',
        'profile',
        'trash',
        'workflows',
        'mail_accounts',
        'mail_rules',
        'statistics',
        'remote_version',
        'status',
      ])
        name: link('$name/'),
    });
  }

  Response _uiSettings(Request request) {
    final user = request.context['user'] as User;
    final row = db.select('SELECT * FROM users WHERE id = ?', [user.id]).first;
    final stored = db.select(
      'SELECT settings FROM ui_settings WHERE user_id = ?',
      [user.id],
    ).firstOrNull;
    final settings = stored == null
        ? <String, dynamic>{}
        : jsonDecode(stored['settings'] as String) as Map<String, dynamic>;
    return json({
      'user': {
        'id': user.id,
        'username': user.username,
        'is_staff': row['is_staff'] == 1,
        'is_superuser': user.isSuperuser,
        'groups': access.groupIds(user),
        'first_name': row['first_name'],
        'last_name': row['last_name'],
      },
      'settings': {
        'app_title': 'paperbuddy',
        // API v10: Sichtbarkeit gespeicherter Ansichten.
        'saved_views': {
          'dashboard_views_visible_ids': [
            for (final r in db.select(
                'SELECT id FROM saved_views x WHERE show_on_dashboard = 1 AND ${access.visibleSql(user, 'savedview', 'x')}'))
              r['id'],
          ],
          'sidebar_views_visible_ids': [
            for (final r in db.select(
                'SELECT id FROM saved_views x WHERE show_in_sidebar = 1 AND ${access.visibleSql(user, 'savedview', 'x')}'))
              r['id'],
          ],
        },
        'update_checking': {'enabled': false, 'backend_setting': 'default'},
        'trash_delay': 30,
        if (oauthUrls != null)
          for (final e in oauthUrls!(user).entries)
            if (e.value != null) '${e.key}_oauth_url': e.value,
        ...settings,
      },
      'permissions': (access.permissions(user).toList()..sort()),
    });
  }

  Future<Response> _saveUiSettings(Request request) async {
    final user = request.context['user'] as User;
    final body = await readBody(request);
    final views = (body['settings'] as Map?)?['saved_views'];
    if (views is Map) {
      // Sichtbarkeit an den Ansichten selbst speichern (für ältere Clients).
      for (final (key, column) in [
        ('dashboard_views_visible_ids', 'show_on_dashboard'),
        ('sidebar_views_visible_ids', 'show_in_sidebar'),
      ]) {
        if (views[key] is! List) continue;
        final ids = asIntList(views[key]);
        final visible = access.changeableSql(user, 'savedview', 'x');
        db.execute('UPDATE saved_views AS x SET $column = 0 WHERE $visible');
        if (ids.isNotEmpty) {
          db.execute('UPDATE saved_views AS x SET $column = 1 WHERE id IN (${ids.join(',')}) AND $visible');
        }
      }
    }
    db.execute(
      'INSERT INTO ui_settings (user_id, settings) VALUES (?, ?) '
      'ON CONFLICT(user_id) DO UPDATE SET settings = excluded.settings',
      [user.id, jsonEncode(body['settings'] ?? {})],
    );
    return json({'success': true});
  }

  /// Aufgabe im Format von API v10.
  Map<String, dynamic> _serializeTaskV10(Row t) => {
    'id': t['id'],
    'task_id': t['task_id'],
    'task_type': 'consume_file',
    'trigger_source': t['trigger_source'],
    'status': (t['status'] as String).toLowerCase(),
    'date_created': t['date_created'],
    'date_done': t['date_done'],
    'result_message': t['result'],
    'input_data': {'filename': t['task_file_name']},
    'related_document_ids': [?t['related_document']],
    'acknowledged': t['acknowledged'] == 1,
    'owner': t['owner'],
  };

  Map<String, dynamic> _serializeTask(Row t) => {
    'id': t['id'],
    'task_id': t['task_id'],
    'task_name': 'consume_file',
    'task_file_name': t['task_file_name'],
    'date_created': t['date_created'],
    'date_done': t['date_done'],
    'type': 'file',
    'status': t['status'],
    'result': t['result'],
    'acknowledged': t['acknowledged'] == 1,
    'related_document': t['related_document']?.toString(),
    'owner': t['owner'],
  };

  /// Paperless liefert hier eine einfache Liste, keine Paginierung.
  /// Bis API v9 eine einfache Liste, ab v10 paginiert.
  Response _tasks(Request request) {
    final user = request.context['user'] as User;
    access.require(user, 'view', 'paperlesstask');
    final q = request.url.queryParameters;
    final where = <String>[if (!user.isSuperuser) 'owner = ${user.id}'];
    final args = <Object?>[];
    if (q['task_id'] != null) {
      where.add('task_id = ?');
      args.add(q['task_id']);
    }
    if (q.containsKey('acknowledged')) {
      where.add('acknowledged = ?');
      args.add(asBool(q['acknowledged']) ? 1 : 0);
    }
    if (q['status'] != null) {
      where.add('status = ?');
      args.add(q['status']!.toUpperCase());
    }
    // Es gibt nur Verarbeitungsaufgaben.
    final type = q['task_type'] ?? q['task_name'] ?? q['type'];
    if (type != null && type != 'consume_file' && type != 'file') where.add('0 = 1');
    final rows = db.select(
      'SELECT * FROM tasks ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
      'ORDER BY date_created DESC, id DESC LIMIT 500',
      args,
    );
    if (apiVersion(request) >= 10) {
      return paginated(
        request,
        (limit, offset) => [for (final t in rows.skip(offset).take(limit)) _serializeTaskV10(t)],
        allIds: [for (final t in rows) t['id'] as int],
      );
    }
    return json([for (final t in rows) _serializeTask(t)]);
  }

  Response _task(Request request) {
    final user = request.context['user'] as User;
    access.require(user, 'view', 'paperlesstask');
    final row = db.select(
      'SELECT * FROM tasks WHERE id = ?${user.isSuperuser ? '' : ' AND owner = ${user.id}'}',
      [int.parse(request.params['id']!)],
    ).firstOrNull;
    if (row == null) throw ApiError(404, 'Not found.');
    return json(apiVersion(request) >= 10 ? _serializeTaskV10(row) : _serializeTask(row));
  }

  /// `/api/config/`: Anwendungseinstellungen wie in Paperless-ngx (eine Zeile).
  Response _config(Request request) => json([
        {
          'id': 1,
          'user_args': null,
          'output_type': 'pdfa',
          'pages': null,
          'language': null,
          'mode': 'skip',
          'skip_archive_file': null,
          'image_dpi': null,
          'unpaper_clean': null,
          'deskew': true,
          'rotate_pages': true,
          'rotate_pages_threshold': null,
          'max_image_pixels': null,
          'color_conversion_strategy': null,
          'app_title': 'PaperBuddy',
          'app_logo': null,
          'barcodes_enabled': false,
          'barcode_enable_tiff_support': false,
          'barcode_string': null,
          'barcode_retain_split_pages': false,
          'barcode_enable_asn': false,
          'barcode_asn_prefix': 'ASN',
          'barcode_upscale': null,
          'barcode_dpi': null,
          'barcode_max_pages': null,
          'barcode_enable_tag': false,
          'barcode_tag_mapping': null,
        },
      ]);

  Future<Response> _acknowledgeTasks(Request request) async {
    final user = request.context['user'] as User;
    access.require(user, 'change', 'paperlesstask');
    final ids = asIntList((await readBody(request))['tasks']);
    if (ids.isNotEmpty) {
      db.execute(
        'UPDATE tasks SET acknowledged = 1 WHERE id IN (${ids.join(',')})'
        '${user.isSuperuser ? '' : ' AND owner = ${user.id}'}',
      );
    }
    return json({'result': ids.length});
  }

  Response _statistics(Request request) {
    final user = request.context['user'] as User;
    final visible = 'd.deleted_at IS NULL AND ${access.visibleSql(user, 'document', 'd')}';
    int count(String sql) => db.select(sql).first.columnAt(0) as int? ?? 0;
    final inboxTags = [
      for (final r in db.select('SELECT id FROM tags x WHERE is_inbox_tag = 1 AND ${access.visibleSql(user, 'tag', 'x')}'))
        r['id'] as int,
    ];
    return json({
      'documents_total': count('SELECT COUNT(*) FROM documents d WHERE $visible'),
      'documents_inbox': inboxTags.isEmpty
          ? null
          : count(
              'SELECT COUNT(DISTINCT dt.document_id) FROM document_tags dt JOIN documents d ON d.id = dt.document_id '
              'WHERE dt.tag_id IN (${inboxTags.join(',')}) AND $visible',
            ),
      'inbox_tag': inboxTags.firstOrNull,
      'inbox_tags': inboxTags,
      'document_file_type_counts': [
        for (final r in db.select(
          'SELECT mime_type, COUNT(*) AS c FROM documents d WHERE $visible GROUP BY mime_type ORDER BY c DESC',
        ))
          {'mime_type': r['mime_type'], 'mime_type_count': r['c']},
      ],
      'character_count': count('SELECT SUM(LENGTH(content)) FROM documents d WHERE $visible'),
      'tag_count': count('SELECT COUNT(*) FROM tags x WHERE ${access.visibleSql(user, 'tag', 'x')}'),
      'correspondent_count':
          count('SELECT COUNT(*) FROM correspondents x WHERE ${access.visibleSql(user, 'correspondent', 'x')}'),
      'document_type_count':
          count('SELECT COUNT(*) FROM document_types x WHERE ${access.visibleSql(user, 'documenttype', 'x')}'),
      'storage_path_count':
          count('SELECT COUNT(*) FROM storage_paths x WHERE ${access.visibleSql(user, 'storagepath', 'x')}'),
      'current_asn': db.select('SELECT MAX(archive_serial_number) AS m FROM documents').first['m'] ?? 0,
    });
  }

  Future<Response> _bulkEditObjects(Request request) async {
    final user = request.context['user'] as User;
    final body = await readBody(request);
    final resource = _taxonomies[body['object_type']] ??
        (throw ApiError.badRequest({'object_type': ['Invalid object type.']}));
    resource.bulk(user, asIntList(body['objects']), body['operation']?.toString() ?? '', body);
    return json({'result': 'OK'});
  }

  Future<Response> _status(Request request) async {
    final toolStatus = await tools.report();
    return json({
      'pngx_version': PaperlessCompat.serverVersion,
      'server_os': 'paperbuddy',
      'install_type': 'paperbuddy',
      'database': {'type': 'sqlite', 'status': 'OK', 'error': null},
      'tasks': {
        'ocr': toolStatus['ocrmypdf']! ? 'OK' : 'WARNING',
        'tools': toolStatus,
      },
    });
  }

  Response _autocomplete(Request request) {
    final term = (request.url.queryParameters['term'] ?? '')
        .trim()
        .toLowerCase();
    final limit = asInt(request.url.queryParameters['limit']) ?? 10;
    if (term.isEmpty) return json(<String>[]);
    final ftsQuery = toFtsQuery(term);
    if (ftsQuery == null) return json(<String>[]);
    final counts = <String, int>{};
    final wordRe = RegExp(r'[\p{L}\p{N}]+', unicode: true);
    final user = request.context['user'] as User;
    for (final row in db.select(
      'SELECT d.content FROM documents d JOIN documents_fts ON documents_fts.rowid = d.id '
      'WHERE documents_fts MATCH ? AND d.deleted_at IS NULL '
      'AND ${access.visibleSql(user, 'document', 'd')} LIMIT 200',
      [ftsQuery],
    )) {
      for (final m in wordRe.allMatches(
        (row['content'] as String).toLowerCase(),
      )) {
        final w = m.group(0)!;
        if (w.startsWith(term)) counts[w] = (counts[w] ?? 0) + 1;
      }
    }
    final words = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return json(words.take(limit).toList());
  }
}
