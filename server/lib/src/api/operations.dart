import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../backup/backup.dart';
import '../version.dart';
import 'documents.dart' show PaperlessCompat;
import 'http_utils.dart';

/// Zähler für `/metrics`, die nicht aus der Datenbank kommen.
class Metrics {
  final started = DateTime.now();

  /// Anfragen je Methode und Statusklasse, z. B. `GET 2xx`.
  final requests = <String, int>{};

  Middleware get middleware => (inner) => (request) async {
    final response = await inner(request);
    final key = '${request.method} ${response.statusCode ~/ 100}xx';
    requests[key] = (requests[key] ?? 0) + 1;
    return response;
  };
}

/// Endpunkte für den Betrieb: Zustand, Metriken und API-Beschreibung.
class OperationsResource {
  OperationsResource({
    required this.db,
    required this.auth,
    required this.metrics,
    required this.routes,
    this.backups,
  });

  final Database db;
  final AuthService auth;
  final Metrics metrics;
  final BackupService? backups;

  /// Alle registrierten Routen (Methode, Pfad) für die OpenAPI-Beschreibung.
  final List<(String, String)> Function() routes;

  /// Eigene Erweiterungen, die Paperless-ngx nicht kennt.
  static const extensions = [
    '/api/reminders/',
    '/api/scanners/',
    '/api/health/',
    '/metrics/',
    '/api/documents/{id}/access_log/',
  ];

  /// Ohne Anmeldung erreichbar.
  static const public = {'/api/token/', '/api/oauth/callback/', '/api/health/', '/share/{slug}/', '/metrics/'};

  void mount(void Function(String method, String path, Function handler) route) {
    route('GET', '/api/health/', health);
    route('GET', '/metrics/', metricsText);
    route('GET', '/api/schema/', schema);
  }

  /// Angemeldeter Administrator oder `null`; `/api/health/` und `/metrics`
  /// liegen außerhalb der allgemeinen Anmeldung.
  Future<User?> _admin(Request request) async {
    try {
      final user = await auth.userForAuthorizationHeader(request.headers['authorization']);
      return user != null && user.isSuperuser ? user : null;
    } on Exception {
      return null;
    }
  }

  /// `ok`, `degraded` (Sicherung fehlt oder fehlgeschlagen) oder `error`
  /// (Datenbank antwortet nicht, HTTP 503). Ohne Anmeldung nur Status und
  /// Version, für Administratoren auch die einzelnen Prüfungen.
  Future<Response> health(Request request) async {
    var database = 'ok';
    try {
      db.select('SELECT 1');
    } on Object catch (e) {
      database = '$e';
    }
    final backup = _backupCheck();
    final status = database != 'ok' ? 'error' : (backup['status'] == 'ok' || backup['status'] == 'off' ? 'ok' : 'degraded');
    final body = <String, Object?>{'status': status, 'version': paperbuddyVersion};
    if (await _admin(request) != null) {
      body['checks'] = {
        'database': database,
        'queue': database == 'ok' ? _taskCounts() : null,
        'backup': backup,
      };
    }
    return json(body, status: database == 'ok' ? 200 : 503);
  }

  Map<String, Object?> _backupCheck() {
    final b = backups;
    if (b == null || b.settings == null) return {'status': 'off'};
    final last = b.lastStatus;
    final started = DateTime.tryParse('${last?['started']}');
    final now = DateTime.now();
    // Täglich geplant: nach gut einem Tag ohne Lauf ist etwas faul.
    const grace = Duration(hours: 26);
    final String status;
    if (started == null) {
      status = now.difference(metrics.started) > grace ? 'missing' : 'ok';
    } else if (last!['ok'] != true) {
      status = 'failed';
    } else {
      status = now.difference(started) > grace ? 'stale' : 'ok';
    }
    return {
      'status': status,
      'last_run': last?['started'],
      'documents': last?['documents'],
      'bytes': last?['bytes'],
      'problems': last?['problems'] ?? const [],
    };
  }

  Map<String, int> _taskCounts() => {
    for (final r in db.select('SELECT status, COUNT(*) AS n FROM tasks GROUP BY status'))
      (r['status'] as String).toLowerCase(): r['n'] as int,
  };

  int _count(String sql, [List<Object?> args = const []]) => db.select(sql, args).first.columnAt(0) as int? ?? 0;

  /// Prometheus-Textformat; nur für Administratoren (Token als Bearer).
  Future<Response> metricsText(Request request) async {
    if (await _admin(request) == null) {
      return Response(401, body: 'Authentication credentials were not provided.\n', headers: {
        'content-type': 'text/plain; charset=utf-8',
        'www-authenticate': 'Bearer',
      });
    }
    final out = StringBuffer();
    void metric(String name, String type, String help, Map<String, num> values) {
      out
        ..writeln('# HELP $name $help')
        ..writeln('# TYPE $name $type');
      values.forEach((labels, value) => out.writeln('$name$labels $value'));
    }

    final today = DateTime.now().toIso8601String().substring(0, 10);
    metric('paperbuddy_info', 'gauge', 'Version von PaperBuddy und der nachgebildeten Paperless-ngx-API.', {
      '{version="$paperbuddyVersion",paperless_api="${PaperlessCompat.serverVersion}"}': 1,
    });
    metric('paperbuddy_uptime_seconds', 'gauge', 'Laufzeit des Servers.', {
      '': DateTime.now().difference(metrics.started).inSeconds,
    });
    metric('process_resident_memory_bytes', 'gauge', 'Belegter Arbeitsspeicher.', {'': ProcessInfo.currentRss});
    metric('paperbuddy_documents', 'gauge', 'Dokumente, aktiv und im Papierkorb.', {
      '{state="active"}': _count('SELECT COUNT(*) FROM documents WHERE deleted_at IS NULL'),
      '{state="trash"}': _count('SELECT COUNT(*) FROM documents WHERE deleted_at IS NOT NULL'),
    });
    metric('paperbuddy_documents_inbox', 'gauge', 'Dokumente mit Posteingangs-Tag.', {
      '': _count(
        'SELECT COUNT(DISTINCT dt.document_id) FROM document_tags dt JOIN tags t ON t.id = dt.tag_id '
        'JOIN documents d ON d.id = dt.document_id WHERE t.is_inbox_tag = 1 AND d.deleted_at IS NULL',
      ),
    });
    metric('paperbuddy_pages', 'gauge', 'Seiten aller aktiven Dokumente.', {
      '': _count('SELECT COALESCE(SUM(page_count), 0) FROM documents WHERE deleted_at IS NULL'),
    });
    metric('paperbuddy_users', 'gauge', 'Aktive Benutzer.', {
      '': _count('SELECT COUNT(*) FROM users WHERE is_active = 1'),
    });
    metric('paperbuddy_tasks', 'gauge', 'Verarbeitungsaufgaben nach Status.', {
      for (final MapEntry(key: status, value: n) in _taskCounts().entries) '{status="$status"}': n,
    });
    metric('paperbuddy_reminders', 'gauge', 'Offene Fristen, davon überfällig.', {
      '{state="open"}': _count('SELECT COUNT(*) FROM reminders WHERE done = 0'),
      '{state="overdue"}': _count('SELECT COUNT(*) FROM reminders WHERE done = 0 AND due < ?', [today]),
    });
    metric('paperbuddy_http_requests_total', 'counter', 'Anfragen seit dem Start nach Methode und Statusklasse.', {
      for (final MapEntry(key: key, value: n) in metrics.requests.entries)
        '{method="${key.split(' ').first}",code="${key.split(' ').last}"}': n,
    });
    metric('paperbuddy_login_failures_total', 'counter', 'Fehlgeschlagene Passwort-Anmeldungen seit dem Start.', {
      '': auth.throttle.totalFailures,
    });
    final backup = backups;
    metric('paperbuddy_backup_enabled', 'gauge', 'Zeitgesteuerte Sicherung eingeschaltet.', {
      '': backup?.settings == null ? 0 : 1,
    });
    final last = backup?.lastStatus;
    final started = DateTime.tryParse('${last?['started']}');
    if (last != null && started != null) {
      metric('paperbuddy_backup_last_run_timestamp_seconds', 'gauge', 'Beginn der letzten Sicherung.', {
        '': started.millisecondsSinceEpoch ~/ 1000,
      });
      metric('paperbuddy_backup_last_success', 'gauge', 'Letzte Sicherung geprüft und in Ordnung.', {
        '': last['ok'] == true ? 1 : 0,
      });
      metric('paperbuddy_backup_last_size_bytes', 'gauge', 'Größe des Inhalts der letzten Sicherung.', {
        '': (last['bytes'] as num?) ?? 0,
      });
      metric('paperbuddy_backup_last_duration_seconds', 'gauge', 'Dauer der letzten Sicherung samt Prüfung.', {
        '': (last['seconds'] as num?) ?? 0,
      });
    }
    return Response.ok(out.toString(), headers: {'content-type': 'text/plain; version=0.0.4; charset=utf-8'});
  }

  /// OpenAPI-Beschreibung aller Routen (wie `/api/schema/` bei Paperless-ngx,
  /// ohne Datenmodelle). Eigene Erweiterungen tragen
  /// `x-paperbuddy-extension: true`.
  Response schema(Request request) => json(openApi(routes()));

  static Map<String, Object?> openApi(List<(String, String)> routes) {
    final paths = <String, Map<String, Object?>>{};
    for (final (method, raw) in routes) {
      final params = <Map<String, Object?>>[];
      final path = raw.replaceAllMapped(RegExp(r'<(\w+)(\|([^>]+))?>'), (m) {
        params.add({
          'name': m[1],
          'in': 'path',
          'required': true,
          'schema': {'type': m[3] == '[0-9]+' ? 'integer' : 'string'},
        });
        return '{${m[1]}}';
      });
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      final tag = segments.first == 'api' ? (segments.length > 1 ? segments[1] : 'api') : segments.first;
      final entry = paths.putIfAbsent(path, () => {
        if (extensions.any(path.startsWith)) 'x-paperbuddy-extension': true,
      });
      entry[method.toLowerCase()] = {
        'tags': [tag],
        'operationId': '${method.toLowerCase()}_${segments.map((s) => s.replaceAll(RegExp(r'[{}]'), '')).join('_')}',
        if (params.isNotEmpty) 'parameters': params,
        if (public.contains(path)) 'security': <Object>[],
        'responses': {
          '200': {'description': 'OK'},
        },
      };
    }
    final sorted = paths.keys.toList()..sort();
    return {
      'openapi': '3.1.0',
      'info': {
        'title': 'PaperBuddy',
        'version': paperbuddyVersion,
        'description':
            'REST-API von PaperBuddy, kompatibel zu Paperless-ngx ${PaperlessCompat.serverVersion} '
            '(API-Versionen ${PaperlessCompat.minApiVersion} bis ${PaperlessCompat.maxApiVersion}). '
            'Pfade mit x-paperbuddy-extension gibt es nur bei PaperBuddy.',
      },
      'security': [
        {'tokenAuth': <Object>[]},
        {'basicAuth': <Object>[]},
      ],
      'components': {
        'securitySchemes': {
          'tokenAuth': {
            'type': 'apiKey',
            'in': 'header',
            'name': 'Authorization',
            'description': 'Token <schlüssel> aus POST /api/token/',
          },
          'basicAuth': {'type': 'http', 'scheme': 'basic'},
        },
      },
      'paths': {for (final p in sorted) p: paths[p]},
    };
  }
}
