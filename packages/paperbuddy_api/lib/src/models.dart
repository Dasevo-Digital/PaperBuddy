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
    this.owner,
    this.userCanChange = true,
    this.customFields = const [],
    this.deletedAt,
    this.versions = const [],
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
  final int? owner;
  final bool userCanChange;

  /// Werte der Custom Fields: `(feld, wert)`.
  final List<CustomFieldValue> customFields;
  final DateTime? deletedAt;

  /// Fassungen, falls je eine neue hochgeladen wurde (älteste zuerst).
  final List<DocumentVersion> versions;

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
      owner: _int(j['owner']),
      userCanChange: j['user_can_change'] as bool? ?? true,
      customFields: [
        for (final c in j['custom_fields'] as List? ?? const [])
          if (c is Map && c['field'] != null)
            CustomFieldValue(_int(c['field'])!, c['value']),
      ],
      deletedAt: _date(j['deleted_at']),
      versions: [
        for (final v in j['versions'] as List? ?? const [])
          if (v is Map<String, dynamic>) DocumentVersion.fromJson(v),
      ],
    );
  }
}

class DocumentVersion {
  const DocumentVersion({
    required this.id,
    required this.added,
    this.label,
    this.checksum,
    this.isRoot = false,
  });
  final int id;
  final DateTime? added;
  final String? label;
  final String? checksum;
  final bool isRoot;

  factory DocumentVersion.fromJson(Map<String, dynamic> j) => DocumentVersion(
    id: j['id'] as int,
    added: _date(j['added']),
    label: j['version_label'] as String?,
    checksum: j['checksum'] as String?,
    isRoot: j['is_root'] as bool? ?? false,
  );
}

/// Eintrag im Änderungsverlauf.
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.timestamp,
    required this.action,
    required this.changes,
    this.actor,
  });
  final int id;
  final DateTime? timestamp;

  /// `create`, `update` oder `delete`
  final String action;
  final Map<String, dynamic> changes;
  final String? actor;

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
    id: j['id'] as int,
    timestamp: _date(j['timestamp']),
    action: j['action'] as String? ?? 'update',
    changes: (j['changes'] as Map?)?.cast<String, dynamic>() ?? const {},
    actor: (j['actor'] as Map?)?['username'] as String?,
  );
}

class CustomFieldValue {
  const CustomFieldValue(this.field, this.value);
  final int field;
  final Object? value;

  Map<String, dynamic> toJson() => {'field': field, 'value': value};
}

/// Gemeinsame Felder von Tags, Korrespondenten, Dokumenttypen und Speicherpfaden.
sealed class Label {
  const Label({
    required this.id,
    required this.name,
    required this.documentCount,
    this.match = '',
    this.matchingAlgorithm = 0,
    this.isInsensitive = true,
    this.owner,
    this.userCanChange = true,
  });
  final int id;
  final String name;
  final int documentCount;
  final String match;
  final int matchingAlgorithm;
  final bool isInsensitive;
  final int? owner;
  final bool userCanChange;
}

/// Gemeinsame Felder aus dem JSON eines Labels.
({String match, int algorithm, bool insensitive, int? owner, bool canChange})
_labelBase(Map<String, dynamic> j) => (
  match: j['match'] as String? ?? '',
  algorithm: j['matching_algorithm'] as int? ?? 0,
  insensitive: j['is_insensitive'] as bool? ?? true,
  owner: _int(j['owner']),
  canChange: j['user_can_change'] as bool? ?? true,
);

class Tag extends Label {
  const Tag({
    required super.id,
    required super.name,
    required super.documentCount,
    super.match,
    super.matchingAlgorithm,
    super.isInsensitive,
    super.owner,
    super.userCanChange,
    this.color = '#a6cee3',
    this.textColor = '#000000',
    this.isInboxTag = false,
  });
  final String color;
  final String textColor;
  final bool isInboxTag;

  factory Tag.fromJson(Map<String, dynamic> j) {
    final b = _labelBase(j);
    return Tag(
      id: j['id'] as int,
      name: j['name'] as String,
      documentCount: j['document_count'] as int? ?? 0,
      match: b.match,
      matchingAlgorithm: b.algorithm,
      isInsensitive: b.insensitive,
      owner: b.owner,
      userCanChange: b.canChange,
      color: j['color'] as String? ?? '#a6cee3',
      textColor: j['text_color'] as String? ?? '#000000',
      isInboxTag: j['is_inbox_tag'] as bool? ?? false,
    );
  }
}

class Correspondent extends Label {
  const Correspondent({
    required super.id,
    required super.name,
    required super.documentCount,
    super.match,
    super.matchingAlgorithm,
    super.isInsensitive,
    super.owner,
    super.userCanChange,
    this.lastCorrespondence,
  });
  final DateTime? lastCorrespondence;

  factory Correspondent.fromJson(Map<String, dynamic> j) {
    final b = _labelBase(j);
    return Correspondent(
      id: j['id'] as int,
      name: j['name'] as String,
      documentCount: j['document_count'] as int? ?? 0,
      match: b.match,
      matchingAlgorithm: b.algorithm,
      isInsensitive: b.insensitive,
      owner: b.owner,
      userCanChange: b.canChange,
      lastCorrespondence: _date(j['last_correspondence']),
    );
  }
}

class DocumentType extends Label {
  const DocumentType({
    required super.id,
    required super.name,
    required super.documentCount,
    super.match,
    super.matchingAlgorithm,
    super.isInsensitive,
    super.owner,
    super.userCanChange,
  });

  factory DocumentType.fromJson(Map<String, dynamic> j) {
    final b = _labelBase(j);
    return DocumentType(
      id: j['id'] as int,
      name: j['name'] as String,
      documentCount: j['document_count'] as int? ?? 0,
      match: b.match,
      matchingAlgorithm: b.algorithm,
      isInsensitive: b.insensitive,
      owner: b.owner,
      userCanChange: b.canChange,
    );
  }
}

class StoragePath extends Label {
  const StoragePath({
    required super.id,
    required super.name,
    required super.documentCount,
    super.match,
    super.matchingAlgorithm,
    super.isInsensitive,
    super.owner,
    super.userCanChange,
    this.path = '',
  });
  final String path;

  factory StoragePath.fromJson(Map<String, dynamic> j) {
    final b = _labelBase(j);
    return StoragePath(
      id: j['id'] as int,
      name: j['name'] as String,
      documentCount: j['document_count'] as int? ?? 0,
      match: b.match,
      matchingAlgorithm: b.algorithm,
      isInsensitive: b.insensitive,
      owner: b.owner,
      userCanChange: b.canChange,
      path: j['path'] as String? ?? '',
    );
  }
}

enum TaskStatus { pending, started, success, failure, unknown }

class ConsumeTask {
  const ConsumeTask({
    this.id,
    required this.taskId,
    required this.status,
    this.fileName,
    this.result,
    this.documentId,
    this.created,
    this.done,
  });

  /// Datenbank-ID, gebraucht für [PaperlessClient.acknowledgeTasks].
  final int? id;
  final String taskId;
  final TaskStatus status;
  final String? fileName;
  final String? result;
  final int? documentId;
  final DateTime? created;
  final DateTime? done;

  bool get isDone =>
      status == TaskStatus.success || status == TaskStatus.failure;

  factory ConsumeTask.fromJson(Map<String, dynamic> j) => ConsumeTask(
    id: _int(j['id']),
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
    done: _date(j['date_done']),
  );
}

/// Kennzahlen laut `/api/statistics/` (Übersicht wie in Paperless-ngx).
class Statistics {
  const Statistics({
    this.documentsTotal = 0,
    this.documentsInbox,
    this.inboxTag,
    this.fileTypes = const [],
    this.characterCount = 0,
    this.tagCount = 0,
    this.correspondentCount = 0,
    this.documentTypeCount = 0,
    this.storagePathCount = 0,
    this.currentAsn = 0,
  });

  final int documentsTotal;

  /// `null`, wenn es keinen Posteingangs-Tag gibt.
  final int? documentsInbox;
  final int? inboxTag;

  /// Dokumente je MIME-Typ, häufigste zuerst.
  final List<({String mimeType, int count})> fileTypes;
  final int characterCount;
  final int tagCount;
  final int correspondentCount;
  final int documentTypeCount;
  final int storagePathCount;
  final int currentAsn;

  factory Statistics.fromJson(Map<String, dynamic> j) => Statistics(
    documentsTotal: _int(j['documents_total']) ?? 0,
    documentsInbox: _int(j['documents_inbox']),
    inboxTag: _int(j['inbox_tag']),
    fileTypes: [
      for (final t in (j['document_file_type_counts'] as List? ?? []))
        (
          mimeType: '${(t as Map)['mime_type']}',
          count: _int(t['mime_type_count']) ?? 0,
        ),
    ]..sort((a, b) => b.count.compareTo(a.count)),
    characterCount: _int(j['character_count']) ?? 0,
    tagCount: _int(j['tag_count']) ?? 0,
    correspondentCount: _int(j['correspondent_count']) ?? 0,
    documentTypeCount: _int(j['document_type_count']) ?? 0,
    storagePathCount: _int(j['storage_path_count']) ?? 0,
    currentAsn: _int(j['current_asn']) ?? 0,
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
  const ServerInfo({
    required this.apiVersion,
    this.serverVersion,
    this.paperbuddyVersion,
  });
  final int apiVersion;

  /// Paperless-ngx-Version laut Server (bei PaperBuddy die kompatible).
  final String? serverVersion;

  /// Gesetzt, wenn der Server PaperBuddy ist.
  final String? paperbuddyVersion;
}
