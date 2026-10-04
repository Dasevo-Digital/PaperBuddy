import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../processing/consumer.dart';
import '../processing/tools.dart';
import '../storage.dart';
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
    required this.store,
    required this.consumer,
    required this.tools,
    this.corsOrigins = const [],
  });

  final Database db;
  final AuthService auth;
  final BlobStore store;
  final Consumer consumer;
  final ExternalTools tools;
  final List<String> corsOrigins;

  static const _public = {'api/token/', 'api/token'};

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
    route('GET', '/api/profile/', _profile);
    route('GET', '/api/users/', _users);
    route('GET', '/api/users/<id|[0-9]+>/', _user);
    route('GET', '/api/groups/', (Request r) => emptyPage());
    route('GET', '/api/tasks/', _tasks);
    route('POST', '/api/tasks/acknowledge/', _acknowledgeTasks);
    route('GET', '/api/statistics/', _statistics);
    route(
      'GET',
      '/api/remote_version/',
      (Request r) => json({
        'version': PaperlessCompat.serverVersion,
        'update_available': false,
      }),
    );
    route('GET', '/api/status/', _status);
    route('GET', '/api/search/autocomplete/', _autocomplete);

    // Noch nicht umgesetzt; leere Listen, damit Clients nicht abbrechen.
    for (final path in [
      'saved_views',
      'custom_fields',
      'share_links',
      'workflows',
      'workflow_triggers',
      'workflow_actions',
      'mail_accounts',
      'mail_rules',
    ]) {
      route('GET', '/api/$path/', (Request r) => emptyPage());
    }

    DocumentsResource(db: db, store: store, consumer: consumer).mount(route);

    TaxonomyResource(
      db: db,
      table: 'tags',
      documentCountSql:
          'SELECT COUNT(*) FROM document_tags WHERE tag_id = x.id',
      extraFields: {
        'color': (v) => v?.toString() ?? '#a6cee3',
        'is_inbox_tag': (v) => asBool(v) ? 1 : 0,
      },
      extraSerializer: (row, out) {
        final color = row['color'] as String;
        out['color'] = color;
        out['text_color'] = textColorFor(color);
        out['is_inbox_tag'] = row['is_inbox_tag'] == 1;
        out['parent'] = null;
        out['children'] = <Object>[];
      },
    ).mount(router, 'tags', route);

    TaxonomyResource(
      db: db,
      table: 'correspondents',
      documentCountSql:
          'SELECT COUNT(*) FROM documents WHERE correspondent_id = x.id',
      extraSerializer: (row, out) {
        out['last_correspondence'] = db.select(
          'SELECT MAX(created) AS m FROM documents WHERE correspondent_id = ?',
          [row['id']],
        ).first['m'];
      },
    ).mount(router, 'correspondents', route);

    TaxonomyResource(
      db: db,
      table: 'document_types',
      documentCountSql:
          'SELECT COUNT(*) FROM documents WHERE document_type_id = x.id',
    ).mount(router, 'document_types', route);

    TaxonomyResource(
      db: db,
      table: 'storage_paths',
      documentCountSql:
          'SELECT COUNT(*) FROM documents WHERE storage_path_id = x.id',
      extraFields: {'path': (v) => v?.toString() ?? ''},
      extraSerializer: (row, out) => out['path'] = row['path'],
    ).mount(router, 'storage_paths', route);

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
        'statistics',
        'remote_version',
        'status',
      ])
        name: link('$name/'),
    });
  }

  Map<String, dynamic> _serializeUser(Row u) => {
    'id': u['id'],
    'username': u['username'],
    'email': u['email'],
    'first_name': u['first_name'],
    'last_name': u['last_name'],
    'date_joined': u['date_joined'],
    'is_staff': u['is_superuser'] == 1,
    'is_active': u['is_active'] == 1,
    'is_superuser': u['is_superuser'] == 1,
    'groups': <int>[],
    'user_permissions': <String>[],
    'inherited_permissions': <String>[],
    'is_mfa_enabled': false,
  };

  Row _userRow(User user) =>
      db.select('SELECT * FROM users WHERE id = ?', [user.id]).first;

  static const _models = [
    'document',
    'tag',
    'correspondent',
    'documenttype',
    'storagepath',
    'savedview',
    'paperlesstask',
    'uisettings',
    'note',
    'customfield',
    'sharelink',
    'workflow',
    'mailaccount',
    'mailrule',
    'user',
    'group',
    'history',
    'appconfig',
  ];

  Response _uiSettings(Request request) {
    final user = request.context['user'] as User;
    final row = _userRow(user);
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
        'is_staff': user.isSuperuser,
        'is_superuser': user.isSuperuser,
        'groups': <int>[],
        'first_name': row['first_name'],
        'last_name': row['last_name'],
      },
      'settings': {
        'app_title': 'paperbuddy',
        'update_checking': {'enabled': false, 'backend_setting': 'default'},
        'trash_delay': 30,
        ...settings,
      },
      // Solange es nur Einzelbenutzer-Rechte gibt, darf jeder alles.
      'permissions': [
        for (final model in _models)
          for (final action in ['view', 'add', 'change', 'delete'])
            '${action}_$model',
      ],
    });
  }

  Future<Response> _saveUiSettings(Request request) async {
    final user = request.context['user'] as User;
    final body = await readBody(request);
    db.execute(
      'INSERT INTO ui_settings (user_id, settings) VALUES (?, ?) '
      'ON CONFLICT(user_id) DO UPDATE SET settings = excluded.settings',
      [user.id, jsonEncode(body['settings'] ?? {})],
    );
    return json({'success': true});
  }

  Response _profile(Request request) {
    final row = _userRow(request.context['user'] as User);
    return json({
      'email': row['email'],
      'password': '**********',
      'first_name': row['first_name'],
      'last_name': row['last_name'],
      'auth_token': auth.tokenFor(request.context['user'] as User),
      'social_accounts': <Object>[],
      'has_usable_password': true,
      'is_mfa_enabled': false,
    });
  }

  Response _users(Request request) {
    final rows = db.select('SELECT * FROM users ORDER BY username');
    return paginated(
      request,
      (limit, offset) => [
        for (final r in rows.skip(offset).take(limit)) _serializeUser(r),
      ],
      allIds: [for (final r in rows) r['id'] as int],
    );
  }

  Response _user(Request request) {
    final row = db.select('SELECT * FROM users WHERE id = ?', [
      int.parse(request.params['id']!),
    ]).firstOrNull;
    if (row == null) throw ApiError(404, 'Not found.');
    return json(_serializeUser(row));
  }

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
  Response _tasks(Request request) {
    final q = request.url.queryParameters;
    final where = <String>[];
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
      args.add(q['status']);
    }
    final rows = db.select(
      'SELECT * FROM tasks ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
      'ORDER BY date_created DESC LIMIT 500',
      args,
    );
    return json([for (final t in rows) _serializeTask(t)]);
  }

  Future<Response> _acknowledgeTasks(Request request) async {
    final ids = asIntList((await readBody(request))['tasks']);
    if (ids.isNotEmpty) {
      db.execute(
        'UPDATE tasks SET acknowledged = 1 WHERE id IN (${ids.join(',')})',
      );
    }
    return json({'result': ids.length});
  }

  Response _statistics(Request request) {
    int count(String sql) => db.select(sql).first.columnAt(0) as int? ?? 0;
    final inboxTags = [
      for (final r in db.select('SELECT id FROM tags WHERE is_inbox_tag = 1'))
        r['id'] as int,
    ];
    return json({
      'documents_total': count('SELECT COUNT(*) FROM documents'),
      'documents_inbox': inboxTags.isEmpty
          ? null
          : count(
              'SELECT COUNT(DISTINCT document_id) FROM document_tags '
              'WHERE tag_id IN (${inboxTags.join(',')})',
            ),
      'inbox_tag': inboxTags.firstOrNull,
      'inbox_tags': inboxTags,
      'document_file_type_counts': [
        for (final r in db.select(
          'SELECT mime_type, COUNT(*) AS c FROM documents GROUP BY mime_type ORDER BY c DESC',
        ))
          {'mime_type': r['mime_type'], 'mime_type_count': r['c']},
      ],
      'character_count': count('SELECT SUM(LENGTH(content)) FROM documents'),
      'tag_count': count('SELECT COUNT(*) FROM tags'),
      'correspondent_count': count('SELECT COUNT(*) FROM correspondents'),
      'document_type_count': count('SELECT COUNT(*) FROM document_types'),
      'storage_path_count': count('SELECT COUNT(*) FROM storage_paths'),
    });
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
    for (final row in db.select(
      'SELECT d.content FROM documents d JOIN documents_fts ON documents_fts.rowid = d.id '
      'WHERE documents_fts MATCH ? LIMIT 200',
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
