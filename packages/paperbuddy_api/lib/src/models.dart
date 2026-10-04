// Datenmodelle mit den Feldnamen der Paperless-ngx-API.

DateTime? _date(Object? v) =>
    v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;
int? _int(Object? v) => v is int ? v : (v is String ? int.tryParse(v) : null);
List<int> _ints(Object? v) =>
    v is List ? [for (final e in v) ?_int(e)] : const [];

/// Eine Seite einer paginierten Liste.
class PageResult<T> {
  const PageResult({
    required this.count,
    required this.results,
    required this.allIds,
    required this.hasNext,
  });

  final int count;
  final List<T> results;
  final List<int> allIds;
  final bool hasNext;

  factory PageResult.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) item,
  ) {
    return PageResult(
      count: json['count'] as int? ?? 0,
      results: [
        for (final r in json['results'] as List? ?? const [])
          item(r as Map<String, dynamic>),
      ],
      allIds: _ints(json['all']),
      hasNext: json['next'] != null,
    );
  }
}

class SearchHit {
  const SearchHit({
    required this.score,
    required this.highlights,
    required this.rank,
  });
  final double score;

  /// HTML-Ausschnitt mit `<span class="match">…</span>` um die Treffer.
  final String highlights;
  final int rank;

  factory SearchHit.fromJson(Map<String, dynamic> j) => SearchHit(
    score: (j['score'] as num?)?.toDouble() ?? 0,
    highlights: j['highlights'] as String? ?? '',
    rank: j['rank'] as int? ?? 0,
  );
}

class Note {
  const Note({
    required this.id,
    required this.note,
    required this.created,
    this.username,
  });
  final int id;
  final String note;
  final DateTime? created;
  final String? username;

  factory Note.fromJson(Map<String, dynamic> j) => Note(
    id: j['id'] as int,
    note: j['note'] as String? ?? '',
    created: _date(j['created']),
    username: (j['user'] is Map)
        ? (j['user'] as Map)['username'] as String?
        : null,
  );
}

class Document {
  const Document({
    required this.id,
    required this.title,
    required this.content,
    required this.tags,
    required this.created,
    this.correspondent,
    this.documentType,
    this.storagePath,
    this.added,
    this.modified,
    this.archiveSerialNumber,
    this.originalFileName,
    this.archivedFileName,
    this.mimeType,
    this.pageCount,
    this.notes = const [],
    this.searchHit,
  });

  final int id;
  final String title;
  final String content;
  final List<int> tags;

  /// Belegdatum (nur der Tag ist relevant).
  final DateTime created;
  final int? correspondent;
  final int? documentType;
  final int? storagePath;
  final DateTime? added;
  final DateTime? modified;
  final int? archiveSerialNumber;
  final String? originalFileName;
  final String? archivedFileName;
  final String? mimeType;
  final int? pageCount;
  final List<Note> notes;
  final SearchHit? searchHit;

  bool get hasArchiveVersion => archivedFileName != null;

  factory Document.fromJson(Map<String, dynamic> j) {
    // Ab API v9 ist `created` ein Datum, davor ein Zeitstempel.
    final createdRaw = (j['created_date'] ?? j['created']) as String?;
    final created = createdRaw == null
        ? null
        : DateTime.tryParse(createdRaw.substring(0, 10));
    return Document(
      id: j['id'] as int,
      title: j['title'] as String? ?? '',
      content: j['content'] as String? ?? '',
      tags: _ints(j['tags']),
      created: created ?? DateTime(1970),
      correspondent: _int(j['correspondent']),
      documentType: _int(j['document_type']),
      storagePath: _int(j['storage_path']),
      added: _date(j['added']),
      modified: _date(j['modified']),
      archiveSerialNumber: _int(j['archive_serial_number']),
      originalFileName: j['original_file_name'] as String?,
      archivedFileName: j['archived_file_name'] as String?,
      mimeType: j['mime_type'] as String?,
      pageCount: _int(j['page_count']),
      notes: [
        for (final n in j['notes'] as List? ?? const [])
          if (n is Map<String, dynamic>) Note.fromJson(n),
      ],
      searchHit: j['__search_hit__'] is Map<String, dynamic>
          ? SearchHit.fromJson(j['__search_hit__'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// Gemeinsame Felder von Tags, Korrespondenten, Dokumenttypen und Speicherpfaden.
sealed class Label {
  const Label({
    required this.id,
    required this.name,
    required this.documentCount,
    this.match = '',
    this.matchingAlgorithm = 0,
  });
  final int id;
  final String name;
  final int documentCount;
  final String match;
  final int matchingAlgorithm;
}

class Tag extends Label {
  const Tag({
    required super.id,
    required super.name,
    required super.documentCount,
    super.match,
    super.matchingAlgorithm,
    this.color = '#a6cee3',
    this.textColor = '#000000',
    this.isInboxTag = false,
  });
  final String color;
  final String textColor;
  final bool isInboxTag;

  factory Tag.fromJson(Map<String, dynamic> j) => Tag(
    id: j['id'] as int,
    name: j['name'] as String,
    documentCount: j['document_count'] as int? ?? 0,
    match: j['match'] as String? ?? '',
    matchingAlgorithm: j['matching_algorithm'] as int? ?? 0,
    color: j['color'] as String? ?? '#a6cee3',
    textColor: j['text_color'] as String? ?? '#000000',
    isInboxTag: j['is_inbox_tag'] as bool? ?? false,
  );
}

class Correspondent extends Label {
  const Correspondent({
    required super.id,
    required super.name,
    required super.documentCount,
    super.match,
    super.matchingAlgorithm,
    this.lastCorrespondence,
  });
  final DateTime? lastCorrespondence;

  factory Correspondent.fromJson(Map<String, dynamic> j) => Correspondent(
    id: j['id'] as int,
    name: j['name'] as String,
    documentCount: j['document_count'] as int? ?? 0,
    match: j['match'] as String? ?? '',
    matchingAlgorithm: j['matching_algorithm'] as int? ?? 0,
    lastCorrespondence: _date(j['last_correspondence']),
  );
}

class DocumentType extends Label {
  const DocumentType({
    required super.id,
    required super.name,
    required super.documentCount,
    super.match,
    super.matchingAlgorithm,
  });

  factory DocumentType.fromJson(Map<String, dynamic> j) => DocumentType(
    id: j['id'] as int,
    name: j['name'] as String,
    documentCount: j['document_count'] as int? ?? 0,
    match: j['match'] as String? ?? '',
    matchingAlgorithm: j['matching_algorithm'] as int? ?? 0,
  );
}

class StoragePath extends Label {
  const StoragePath({
    required super.id,
    required super.name,
    required super.documentCount,
    super.match,
    super.matchingAlgorithm,
    this.path = '',
  });
  final String path;

  factory StoragePath.fromJson(Map<String, dynamic> j) => StoragePath(
    id: j['id'] as int,
    name: j['name'] as String,
    documentCount: j['document_count'] as int? ?? 0,
    match: j['match'] as String? ?? '',
    matchingAlgorithm: j['matching_algorithm'] as int? ?? 0,
    path: j['path'] as String? ?? '',
  );
}

enum TaskStatus { pending, started, success, failure, unknown }

class ConsumeTask {
  const ConsumeTask({
    required this.taskId,
    required this.status,
    this.fileName,
    this.result,
    this.documentId,
    this.created,
  });

  final String taskId;
  final TaskStatus status;
  final String? fileName;
  final String? result;
  final int? documentId;
  final DateTime? created;

  bool get isDone =>
      status == TaskStatus.success || status == TaskStatus.failure;

  factory ConsumeTask.fromJson(Map<String, dynamic> j) => ConsumeTask(
    taskId: j['task_id'] as String,
    status: switch (j['status']) {
      'PENDING' => TaskStatus.pending,
      'STARTED' => TaskStatus.started,
      'SUCCESS' => TaskStatus.success,
      'FAILURE' => TaskStatus.failure,
      _ => TaskStatus.unknown,
    },
    fileName: j['task_file_name'] as String?,
    result: j['result'] as String?,
    documentId: _int(j['related_document']),
    created: _date(j['date_created']),
  );
}

/// Angemeldeter Benutzer laut `/api/ui_settings/`.
class CurrentUser {
  const CurrentUser({
    required this.id,
    required this.username,
    required this.isSuperuser,
    required this.permissions,
    this.displayName,
  });
  final int id;
  final String username;
  final bool isSuperuser;
  final Set<String> permissions;
  final String? displayName;

  bool can(String action, String model) =>
      isSuperuser || permissions.contains('${action}_$model');

  factory CurrentUser.fromUiSettings(Map<String, dynamic> j) {
    final user = j['user'] as Map<String, dynamic>? ?? const {};
    final name = '${user['first_name'] ?? ''} ${user['last_name'] ?? ''}'
        .trim();
    return CurrentUser(
      id: user['id'] as int? ?? 0,
      username: user['username'] as String? ?? '',
      isSuperuser: user['is_superuser'] as bool? ?? false,
      permissions: {
        for (final p in j['permissions'] as List? ?? const []) '$p',
      },
      displayName: name.isEmpty ? null : name,
    );
  }
}

/// Heruntergeladene Datei mit Namen und Typ laut Server.
class DownloadedFile {
  const DownloadedFile(this.bytes, this.fileName, this.mimeType);
  final List<int> bytes;
  final String fileName;
  final String mimeType;

  bool get isPdf => mimeType == 'application/pdf';
  bool get isImage => mimeType.startsWith('image/');
  bool get isText => mimeType.startsWith('text/');
}

/// Was der Server beim Verbinden über sich verrät.
class ServerInfo {
  const ServerInfo({required this.apiVersion, this.serverVersion});
  final int apiVersion;
  final String? serverVersion;
}
