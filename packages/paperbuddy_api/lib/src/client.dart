import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'admin_models.dart';
import 'errors.dart';
import 'filter.dart';
import 'models.dart';

part 'client_admin.dart';

/// Zugriff auf einen PaperBuddy- oder Paperless-ngx-Server.
///
/// Erzeugen über [PaperlessClient.login] oder [PaperlessClient.connect];
/// dabei wird die API-Version mit dem Server ausgehandelt.
class PaperlessClient {
  PaperlessClient._(
    this.baseUrl,
    this.token,
    this.server,
    this.user,
    this._http,
  );

  /// Höchste API-Version, die dieser Client versteht.
  static const maxApiVersion = 9;
  static const _timeout = Duration(seconds: 30);
  static const _uploadTimeout = Duration(minutes: 10);

  /// Basis-URL ohne abschließenden Schrägstrich, z. B. `http://nas:8000`.
  final Uri baseUrl;
  final String token;
  final ServerInfo server;
  final CurrentUser user;
  final http.Client _http;

  int get apiVersion => server.apiVersion;

  /// Macht aus einer Benutzereingabe wie `nas:8000/` eine saubere Basis-URL.
  static Uri normalizeBaseUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) throw ApiException('Bitte eine Server-Adresse angeben.');
    if (!s.contains('://')) s = 'http://$s';
    var uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) {
      throw ApiException('Ungültige Server-Adresse: $input');
    }
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (path.endsWith('/api')) path = path.substring(0, path.length - 4);
    return uri.replace(path: path, query: null, fragment: null);
  }

  /// Meldet sich mit Benutzername und Passwort an und holt einen Token.
  ///
  /// Mit aktiver Zwei-Faktor-Anmeldung wirft der erste Versuch
  /// [MfaRequiredException]; dann erneut mit [code] aufrufen.
  static Future<PaperlessClient> login(
    String serverAddress,
    String username,
    String password, {
    String? code,
    http.Client? httpClient,
  }) async {
    final base = normalizeBaseUrl(serverAddress);
    final client = httpClient ?? http.Client();
    final response = await _guard(
      () => client
          .post(
            _resolve(base, '/api/token/', null),
            headers: {'accept': 'application/json'},
            body: {
              'username': username,
              'password': password,
              if (code != null && code.trim().isNotEmpty) 'code': code.trim(),
            },
          )
          .timeout(_timeout),
    );
    final body = _decode(response);
    if (response.statusCode == 400) {
      final errors = body is Map ? body['non_field_errors'] : null;
      final first = errors is List && errors.isNotEmpty ? '${errors.first}' : '';
      // Meldungen wie bei Paperless-ngx.
      if (first == 'MFA code is required') throw MfaRequiredException();
      if (first == 'Invalid MFA code') throw MfaRequiredException(invalid: true);
      if (first.startsWith('Too many invalid MFA codes')) {
        throw MfaRequiredException(
          invalid: true,
          message: 'Zu viele falsche Codes. Bitte in einigen Minuten erneut versuchen.',
        );
      }
      throw ApiException(
        'Benutzername oder Passwort ist falsch.',
        statusCode: 400,
      );
    }
    if (response.statusCode != 200 ||
        body is! Map ||
        body['token'] is! String) {
      throw _error(response, body);
    }
    return connect(
      base.toString(),
      body['token'] as String,
      httpClient: client,
    );
  }

  /// Verbindet mit einem vorhandenen Token (z. B. aus dem sicheren Speicher).
  static Future<PaperlessClient> connect(
    String serverAddress,
    String token, {
    http.Client? httpClient,
  }) async {
    final base = normalizeBaseUrl(serverAddress);
    final client = httpClient ?? http.Client();
    // Ohne Versionsangabe fragen; der Server nennt seine höchste Version
    // im Header `X-Api-Version`.
    final response = await _guard(
      () => client
          .get(
            _resolve(base, '/api/ui_settings/', null),
            headers: {
              'authorization': 'Token $token',
              'accept': 'application/json',
            },
          )
          .timeout(_timeout),
    );
    final body = _decode(response);
    if (response.statusCode != 200 || body is! Map<String, dynamic>) {
      if (response.statusCode == 404 ||
          (body == null && response.statusCode == 200)) {
        throw ApiException(
          'Unter dieser Adresse läuft kein PaperBuddy- oder Paperless-Server.',
          statusCode: response.statusCode,
        );
      }
      throw _error(response, body);
    }
    final serverMax = int.tryParse(response.headers['x-api-version'] ?? '');
    final info = ServerInfo(
      apiVersion: serverMax == null
          ? maxApiVersion
          : (serverMax < maxApiVersion ? serverMax : maxApiVersion),
      serverVersion: response.headers['x-version'],
    );
    return PaperlessClient._(
      base,
      token,
      info,
      CurrentUser.fromUiSettings(body),
      client,
    );
  }

  void close() => _http.close();

  // ---------------------------------------------------------------------------
  // HTTP-Grundlagen

  static Uri _resolve(Uri base, String path, Map<String, String>? query) =>
      base.replace(
        path: '${base.path}$path',
        queryParameters: query == null || query.isEmpty ? null : query,
      );

  Map<String, String> get _headers => {
    'authorization': 'Token $token',
    'accept': 'application/json; version=$apiVersion',
  };

  static Future<http.Response> _guard(
    Future<http.Response> Function() send,
  ) async {
    try {
      return await send();
    } on TimeoutException {
      throw ApiException('Der Server antwortet nicht.');
    } on http.ClientException catch (e) {
      throw ApiException('Server nicht erreichbar: ${e.message}');
    }
  }

  static Object? _decode(http.Response r) {
    if (r.bodyBytes.isEmpty) return null;
    if (!(r.headers['content-type'] ?? '').contains('json')) return null;
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      return null;
    }
  }

  static ApiException _error(http.Response r, Object? body) {
    if (r.statusCode == 401) {
      return ApiException(
        'Anmeldung abgelaufen oder ungültig.',
        statusCode: 401,
      );
    }
    return ApiException.fromBody(r.statusCode, body);
  }

  Future<Object?> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? json,
    Set<int> ok = const {200, 201, 204},
  }) async {
    final request = http.Request(method, _resolve(baseUrl, path, query))
      ..headers.addAll(_headers);
    if (json != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(json);
    }
    final response = await _guard(
      () async =>
          http.Response.fromStream(await _http.send(request).timeout(_timeout)),
    );
    final body = _decode(response);
    if (!ok.contains(response.statusCode)) throw _error(response, body);
    return body;
  }

  Future<Map<String, dynamic>> _getMap(
    String path, [
    Map<String, String>? query,
  ]) async => (await _send('GET', path, query: query)) as Map<String, dynamic>;

  Future<List<T>> _all<T>(
    String path,
    T Function(Map<String, dynamic>) item,
  ) async {
    final result = <T>[];
    for (var page = 1; ; page++) {
      final p = PageResult.fromJson(
        await _getMap(path, {'page': '$page', 'page_size': '1000'}),
        item,
      );
      result.addAll(p.results);
      if (!p.hasNext) return result;
    }
  }

  Future<Uint8List> _bytes(String path, [Map<String, String>? query]) async {
    final r = await _guard(
      () => _http
          .get(_resolve(baseUrl, path, query), headers: _headers)
          .timeout(_uploadTimeout),
    );
    if (r.statusCode != 200) throw _error(r, _decode(r));
    return r.bodyBytes;
  }

  // ---------------------------------------------------------------------------
  // Dokumente

  Future<PageResult<Document>> documents({
    DocumentFilter filter = const DocumentFilter(),
    int page = 1,
    int pageSize = 50,
    bool truncateContent = true,
  }) async {
    final json = await _getMap('/api/documents/', {
      ...filter.toQueryParameters(),
      'page': '$page',
      'page_size': '$pageSize',
      if (truncateContent) 'truncate_content': 'true',
    });
    return PageResult.fromJson(json, Document.fromJson);
  }

  Future<Document> document(int id) async =>
      Document.fromJson(await _getMap('/api/documents/$id/'));

  /// Ändert einzelne Felder, z. B. `{'title': 'Neu', 'tags': [1, 2]}`.
  Future<Document> updateDocument(int id, Map<String, Object?> changes) async =>
      Document.fromJson(
        (await _send('PATCH', '/api/documents/$id/', json: changes))
            as Map<String, dynamic>,
      );

  Future<void> deleteDocument(int id) => _send('DELETE', '/api/documents/$id/');

  Future<Uint8List> thumbnail(int id, {int? version}) => _bytes(
    '/api/documents/$id/thumb/',
    {if (version != null) 'version': '$version'},
  );

  /// Archiv-PDF bzw. – mit [original] oder wenn es keins gibt – die Originaldatei.
  Future<Uint8List> download(int id, {bool original = false}) => _bytes(
    '/api/documents/$id/download/',
    {if (original) 'original': 'true'},
  );

  /// Wie [download], zusätzlich mit Dateiname und Typ aus den Headern.
  Future<DownloadedFile> downloadFile(
    int id, {
    bool original = false,
    int? version,
  }) async {
    final r = await _guard(
      () => _http
          .get(
            _resolve(baseUrl, '/api/documents/$id/download/', {
              if (original) 'original': 'true',
              if (version != null) 'version': '$version',
            }),
            headers: _headers,
          )
          .timeout(_uploadTimeout),
    );
    if (r.statusCode != 200) throw _error(r, _decode(r));
    return DownloadedFile(
      r.bodyBytes,
      _fileNameFrom(r.headers['content-disposition']) ?? 'dokument-$id',
      (r.headers['content-type'] ?? 'application/octet-stream')
          .split(';')
          .first
          .trim(),
    );
  }

  static String? _fileNameFrom(String? disposition) {
    if (disposition == null) return null;
    final star = RegExp(
      r"filename\*=(?:UTF-8|utf-8)''([^;]+)",
    ).firstMatch(disposition);
    if (star != null) return Uri.decodeComponent(star.group(1)!.trim());
    return RegExp(r'filename="([^"]+)"').firstMatch(disposition)?.group(1);
  }

  Future<List<Note>> addNote(int documentId, String note) async => [
    for (final n
        in (await _send(
              'POST',
              '/api/documents/$documentId/notes/',
              json: {'note': note},
            ))
            as List)
      Note.fromJson(n as Map<String, dynamic>),
  ];

  Future<void> deleteNote(int documentId, int noteId) => _send(
    'DELETE',
    '/api/documents/$documentId/notes/',
    query: {'id': '$noteId'},
  );

  /// Sammelbearbeitung, z. B. `bulkEdit(ids, 'add_tag', {'tag': 3})`.
  /// Methoden: `set_correspondent`, `set_document_type`, `set_storage_path`,
  /// `add_tag`, `remove_tag`, `modify_tags`, `delete`.
  Future<void> bulkEdit(
    List<int> documents,
    String method, [
    Map<String, Object?> parameters = const {},
  ]) => _send(
    'POST',
    '/api/documents/bulk_edit/',
    json: {'documents': documents, 'method': method, 'parameters': parameters},
  );

  Future<int> nextArchiveSerialNumber() async =>
      (await _send('GET', '/api/documents/next_asn/')) as int;

  /// Wortvorschläge für die Suche.
  Future<List<String>> autocomplete(String term, {int limit = 10}) async => [
    for (final w
        in (await _send(
              'GET',
              '/api/search/autocomplete/',
              query: {'term': term, 'limit': '$limit'},
            ))
            as List)
      '$w',
  ];

  /// Lädt eine Datei hoch. Liefert die Task-ID; den Fortschritt über [task]
  /// bzw. [waitForTask] verfolgen.
  Future<String> uploadDocument(
    List<int> bytes,
    String filename, {
    String? title,
    DateTime? created,
    int? correspondent,
    int? documentType,
    int? storagePath,
    List<int> tags = const [],
    int? archiveSerialNumber,
  }) async {
    final request =
        http.MultipartRequest(
            'POST',
            _resolve(baseUrl, '/api/documents/post_document/', null),
          )
          ..headers.addAll(_headers)
          ..files.add(
            http.MultipartFile.fromBytes('document', bytes, filename: filename),
          );
    void field(String name, Object? value) {
      if (value != null && '$value'.isNotEmpty) {
        request.files.add(http.MultipartFile.fromString(name, '$value'));
      }
    }

    // Felder als Teile ohne Dateinamen, damit `tags` mehrfach vorkommen darf.
    field('title', title);
    if (created != null) {
      field('created', created.toIso8601String().substring(0, 10));
    }
    field('correspondent', correspondent);
    field('document_type', documentType);
    field('storage_path', storagePath);
    field('archive_serial_number', archiveSerialNumber);
    for (final t in tags) {
      field('tags', t);
    }
    final response = await _guard(
      () async => http.Response.fromStream(
        await _http.send(request).timeout(_uploadTimeout),
      ),
    );
    final body = _decode(response);
    if (response.statusCode != 200 || body is! String) {
      throw _error(response, body);
    }
    return body;
  }

  // ---------------------------------------------------------------------------
  // Tasks

  Future<ConsumeTask?> task(String taskId) async {
    final list =
        (await _send('GET', '/api/tasks/', query: {'task_id': taskId})) as List;
    return list.isEmpty
        ? null
        : ConsumeTask.fromJson(list.first as Map<String, dynamic>);
  }

  Future<List<ConsumeTask>> tasks({bool unacknowledgedOnly = false}) async => [
    for (final t
        in (await _send(
              'GET',
              '/api/tasks/',
              query: {if (unacknowledgedOnly) 'acknowledged': 'false'},
            ))
            as List)
      ConsumeTask.fromJson(t as Map<String, dynamic>),
  ];

  Future<void> acknowledgeTasks(List<int> ids) =>
      _send('POST', '/api/tasks/acknowledge/', json: {'tasks': ids});

  /// Fragt den Task ab, bis er fertig ist.
  Future<ConsumeTask> waitForTask(
    String taskId, {
    Duration interval = const Duration(seconds: 1),
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final t = await task(taskId);
      if (t != null && t.isDone) return t;
      if (DateTime.now().isAfter(deadline)) {
        throw ApiException('Die Verarbeitung dauert ungewöhnlich lange.');
      }
      await Future<void>.delayed(interval);
    }
  }

  // ---------------------------------------------------------------------------
  // Tags, Korrespondenten, Dokumenttypen, Speicherpfade

  Future<List<Tag>> tags() => _all('/api/tags/', Tag.fromJson);
  Future<List<Correspondent>> correspondents() =>
      _all('/api/correspondents/', Correspondent.fromJson);
  Future<List<DocumentType>> documentTypes() =>
      _all('/api/document_types/', DocumentType.fromJson);
  Future<List<StoragePath>> storagePaths() =>
      _all('/api/storage_paths/', StoragePath.fromJson);

  Future<Tag> createTag(
    String name, {
    String? color,
    bool isInboxTag = false,
  }) async => Tag.fromJson(
    (await _send(
          'POST',
          '/api/tags/',
          json: {
            'name': name,
            'color': ?color,
            'is_inbox_tag': isInboxTag,
            'matching_algorithm': 6,
          },
        ))
        as Map<String, dynamic>,
  );

  Future<Correspondent> createCorrespondent(String name) async =>
      Correspondent.fromJson(
        (await _send(
              'POST',
              '/api/correspondents/',
              json: {'name': name, 'matching_algorithm': 6},
            ))
            as Map<String, dynamic>,
      );

  Future<StoragePath> createStoragePath(String name, String path) async =>
      StoragePath.fromJson(
        (await _send(
              'POST',
              '/api/storage_paths/',
              json: {'name': name, 'path': path, 'matching_algorithm': 0},
            ))
            as Map<String, dynamic>,
      );

  Future<DocumentType> createDocumentType(String name) async =>
      DocumentType.fromJson(
        (await _send(
              'POST',
              '/api/document_types/',
              json: {'name': name, 'matching_algorithm': 6},
            ))
            as Map<String, dynamic>,
      );
}
