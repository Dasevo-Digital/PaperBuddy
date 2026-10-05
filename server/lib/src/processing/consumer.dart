import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../db.dart';
import '../storage.dart';
import 'classifier.dart';
import 'matching.dart';
import 'tools.dart';

final _log = Logger('consumer');

const supportedMimeTypes = {
  'application/pdf': 'pdf',
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/tiff': 'tiff',
  'image/webp': 'webp',
  'text/plain': 'txt',
};

/// Herkunft eines Dokuments (Werte wie `DocumentSource` in Paperless-ngx).
enum ConsumeSource {
  consumeFolder(1),
  api(2),
  mail(3),
  scanner(4);

  const ConsumeSource(this.value);
  final int value;
}

/// Vorgaben beim Upload (entspricht den Feldern von `post_document`) und
/// Ergebnis von Workflows mit dem Auslöser „Verarbeitung gestartet“.
class ConsumeOverrides {
  ConsumeOverrides({
    this.title,
    this.created,
    this.correspondent,
    this.documentType,
    this.storagePath,
    List<int> tags = const [],
    this.archiveSerialNumber,
    this.owner,
    List<int>? customFields,
    Map<int, Object?>? customFieldValues,
  })  : tags = [...tags],
        customFieldValues = {
          ...?customFieldValues,
          for (final f in customFields ?? const <int>[]) f: null,
        };

  String? title;
  DateTime? created;
  int? correspondent;
  int? documentType;
  int? storagePath;
  final List<int> tags;
  int? archiveSerialNumber;
  int? owner;

  /// Custom Fields, die das Dokument bekommt (Wert `null` = leer).
  final Map<int, Object?> customFieldValues;

  /// Titel-Vorlage aus Workflows, z. B. `{correspondent} {created_year}`;
  /// wird nach dem Anlegen mit den endgültigen Daten ausgefüllt.
  String? titleTemplate;

  /// Freigaben aus Workflows.
  final viewUsers = <int>{};
  final viewGroups = <int>{};
  final changeUsers = <int>{};
  final changeGroups = <int>{};
}

/// Erweiterungspunkte für Workflows.
abstract interface class ConsumeHooks {
  /// Vor der Verarbeitung; darf [overrides] ändern.
  void consumptionStarted({
    required String fileName,
    required String? path,
    required ConsumeSource source,
    required ConsumeOverrides overrides,
    int? mailRule,
  });

  /// Füllt eine Titel-Vorlage mit den Daten des Dokuments.
  String renderTitle(String template, int documentId);

  /// Nachdem das Dokument angelegt wurde.
  Future<void> documentAdded(int documentId, {required ConsumeSource source, required String fileName, int? mailRule});
}

class ConsumeError implements Exception {
  ConsumeError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Ergebnis der Text- und Bildverarbeitung einer Datei.
class _Extracted {
  _Extracted(this.content, this.archive, this.thumbnail, this.pages);
  final String content;
  final String? archive;
  final String? thumbnail;
  final int? pages;
}

/// Nimmt Dateien entgegen und verarbeitet sie nacheinander im Hintergrund.
class Consumer {
  Consumer({
    required this.db,
    required this.store,
    required this.tools,
    required this.workDir,
    DocumentClassifier? classifier,
  }) : classifier = classifier ?? DocumentClassifier(db);

  final Database db;
  final BlobStore store;
  final ExternalTools tools;
  final String workDir;
  final DocumentClassifier classifier;
  ConsumeHooks? hooks;

  Future<void> _queue = Future.value();
  final _uuid = const Uuid();
  final _pending = <String, Future<void>>{};

  /// Legt einen Task an und gibt dessen UUID sofort zurück.
  ///
  /// [file] wird in ein eigenes Arbeitsverzeichnis verschoben bzw. kopiert,
  /// der Aufrufer muss sich danach nicht mehr darum kümmern.
  Future<String> submit(
    File file, {
    required String originalName,
    ConsumeOverrides? overrides,
    bool moveSource = false,
    ConsumeSource source = ConsumeSource.api,
    String? sourcePath,
    int? mailRule,
  }) async {
    final taskId = _uuid.v4();
    final staged = File(p.join(workDir, 'incoming', '$taskId${p.extension(originalName)}'));
    await staged.parent.create(recursive: true);
    if (moveSource) {
      try {
        await file.rename(staged.path);
      } on FileSystemException {
        await file.copy(staged.path);
        await file.delete();
      }
    } else {
      await file.copy(staged.path);
    }

    final o = overrides ?? ConsumeOverrides();
    db.execute(
      'INSERT INTO tasks (task_id, task_file_name, date_created, status, owner) VALUES (?, ?, ?, ?, ?)',
      [taskId, originalName, nowIso(), 'PENDING', o.owner],
    );

    final done = Completer<void>();
    _queue = _queue.then((_) async {
      await _process(taskId, staged, originalName, o, source, sourcePath, mailRule);
      done.complete();
    });
    _pending[taskId] = done.future;
    unawaited(done.future.whenComplete(() => _pending.remove(taskId)));
    return taskId;
  }

  /// Führt [action] in der Warteschlange aus, damit Dateien nicht
  /// gleichzeitig verarbeitet und bearbeitet werden.
  Future<T> runExclusive<T>(Future<T> Function() action) {
    final done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await action());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// Für Tests: wartet, bis ein Task abgeschlossen ist.
  Future<void> waitFor(String taskId) => _pending[taskId] ?? Future.value();

  /// Wartet, bis die Warteschlange leer ist.
  Future<void> idle() => _queue;

  void _setTask(String taskId, String status, {String? result, int? document}) {
    final finished = status == 'SUCCESS' || status == 'FAILURE';
    db.execute(
      'UPDATE tasks SET status = ?, result = COALESCE(?, result), '
      'related_document = COALESCE(?, related_document), '
      'date_done = CASE WHEN ? THEN ? ELSE date_done END WHERE task_id = ?',
      [status, result, document, finished ? 1 : 0, nowIso(), taskId],
    );
  }

  Future<void> _process(String taskId, File staged, String originalName, ConsumeOverrides o,
      ConsumeSource source, String? sourcePath, int? mailRule) async {
    _setTask(taskId, 'STARTED');
    final scratch = Directory(p.join(workDir, 'scratch', taskId));
    try {
      hooks?.consumptionStarted(
          fileName: originalName, path: sourcePath, source: source, overrides: o, mailRule: mailRule);
      final id = await _consume(staged, originalName, o, scratch);
      final template = o.titleTemplate;
      if (template != null && hooks != null) {
        final title = hooks!.renderTitle(template, id).trim();
        if (title.isNotEmpty) db.execute('UPDATE documents SET title = ? WHERE id = ?', [title, id]);
      }
      await hooks?.documentAdded(id, source: source, fileName: originalName, mailRule: mailRule);
      _setTask(taskId, 'SUCCESS', result: 'Success. New document id $id created', document: id);
      _log.info('$originalName → Dokument #$id');
    } catch (e, st) {
      final message = e is ConsumeError ? e.message : '$originalName: $e';
      if (e is! ConsumeError) _log.severe('Verarbeitung fehlgeschlagen', e, st);
      _setTask(taskId, 'FAILURE', result: message);
    } finally {
      if (await scratch.exists()) await scratch.delete(recursive: true);
      if (await staged.exists()) await staged.delete();
    }
  }

  static String detectMime(String fileName, List<int> bytes) =>
      lookupMimeType(fileName, headerBytes: bytes.take(defaultMagicNumbersMaxLength).toList()) ??
      'application/octet-stream';

  /// Texterkennung, Archiv-PDF, Vorschaubild und Seitenzahl.
  Future<_Extracted> _extract(File source, String mime, Directory scratch) async {
    final ext = supportedMimeTypes[mime]!;
    final isPdf = mime == 'application/pdf';
    final isImage = mime.startsWith('image/');
    String content = '';
    String? archive;
    String? thumbnail;
    int? pages;

    if (mime == 'text/plain') {
      content = utf8.decode(await source.readAsBytes(), allowMalformed: true);
    } else {
      final ocrInput = p.join(scratch.path, 'input.$ext');
      await source.copy(ocrInput);
      final archived = p.join(scratch.path, 'archive.pdf');
      if (await tools.ocrPdf(ocrInput, archived, isImage: isImage) ||
          (isImage && await tools.imageToPdf(ocrInput, archived))) {
        archive = archived;
      }
      final textSource = archive ?? (isPdf ? ocrInput : null);
      if (textSource != null) {
        content = await tools.pdfText(textSource) ?? '';
        pages = await tools.pdfPageCount(textSource);
        final thumb = p.join(scratch.path, 'thumb.png');
        if (await tools.pdfThumbnail(textSource, thumb)) thumbnail = thumb;
      } else if (isImage) {
        content = await tools.imageText(ocrInput) ?? '';
        thumbnail = ocrInput;
      }
    }
    return _Extracted(content.replaceAll('\f', '\n').trim(), archive, thumbnail, pages);
  }

  Future<int> _consume(File source, String originalName, ConsumeOverrides o, Directory scratch) async {
    await scratch.create(recursive: true);
    final bytes = await source.readAsBytes();
    final checksum = md5.convert(bytes).toString();

    final duplicate = db.select('SELECT id, title, deleted_at FROM documents WHERE checksum = ?', [checksum]);
    if (duplicate.isNotEmpty) {
      final d = duplicate.first;
      final where = d['deleted_at'] != null ? ' Note: existing document is in the trash.' : '';
      throw ConsumeError('Not consuming $originalName: It is a duplicate of ${d['title']} (#${d['id']}).$where');
    }

    final mime = detectMime(originalName, bytes);
    final ext = supportedMimeTypes[mime];
    if (ext == null) throw ConsumeError('Not consuming $originalName: Unsupported mime type $mime');

    final x = await _extract(source, mime, scratch);
    classifier.trainIfNeeded();
    final matched = matchContent(db, '${p.basenameWithoutExtension(originalName)}\n${x.content}',
        classifier: classifier);
    final created = o.created ?? findDate(x.content) ?? DateTime.now();
    final title = (o.title?.trim().isNotEmpty ?? false) ? o.title!.trim() : p.basenameWithoutExtension(originalName);
    final now = nowIso();

    db.execute('BEGIN;');
    late int id;
    try {
      db.execute(
        'INSERT INTO documents (title, content, correspondent_id, document_type_id, '
        'storage_path_id, created, modified, added, archive_serial_number, '
        'original_filename, mime_type, checksum, original_path, page_count, owner) '
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', ?, ?)",
        [
          title,
          x.content,
          o.correspondent ?? matched.correspondent,
          o.documentType ?? matched.documentType,
          o.storagePath ?? matched.storagePath,
          dateOnly(created),
          now,
          now,
          o.archiveSerialNumber,
          originalName,
          mime,
          checksum,
          x.pages,
          o.owner,
        ],
      );
      id = db.lastInsertRowId;
      final name = id.toString().padLeft(7, '0');
      final originalKey = 'originals/$name.$ext';
      final archiveKey = x.archive == null ? null : 'archive/$name.pdf';
      final thumbKey = x.thumbnail == null ? null : 'thumbnails/$name${p.extension(x.thumbnail!)}';
      await store.put(originalKey, source);
      if (x.archive != null) await store.put(archiveKey!, File(x.archive!));
      if (x.thumbnail != null) await store.put(thumbKey!, File(x.thumbnail!));
      db.execute(
        'UPDATE documents SET original_path = ?, archive_path = ?, thumbnail_path = ? WHERE id = ?',
        [originalKey, archiveKey, thumbKey, id],
      );
      final stmt = db.prepare(
        'INSERT OR IGNORE INTO document_tags (document_id, tag_id) SELECT ?, id FROM tags WHERE id = ?',
      );
      for (final tag in {...o.tags, ...matched.tags}) {
        stmt.execute([id, tag]);
      }
      stmt.close();
      for (final e in o.customFieldValues.entries) {
        db.execute(
          'INSERT OR IGNORE INTO document_custom_fields (document_id, field_id, value) '
          'SELECT ?, id, ? FROM custom_fields WHERE id = ?',
          [id, e.value == null ? null : jsonEncode(e.value), e.key],
        );
      }
      for (final (perm, column, ids) in [
        ('view', 'user_id', o.viewUsers),
        ('view', 'group_id', o.viewGroups),
        ('change', 'user_id', o.changeUsers),
        ('change', 'group_id', o.changeGroups),
      ]) {
        for (final target in ids) {
          db.execute(
            'INSERT INTO object_permissions (object_type, object_id, permission, $column) '
            "VALUES ('document', ?, ?, ?)",
            [id, perm, target],
          );
        }
      }
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
    return id;
  }

  /// Texterkennung und Vorschau eines vorhandenen Dokuments neu erzeugen
  /// (Bulk-Edit `reprocess`). Metadaten bleiben unverändert.
  Future<void> reprocess(int id) {
    final done = Completer<void>();
    _queue = _queue.then((_) async {
      final scratch = Directory(p.join(workDir, 'scratch', 'reprocess-$id'));
      try {
        final row = db.select(
          'SELECT original_path, archive_path, thumbnail_path, mime_type FROM documents WHERE id = ?',
          [id],
        ).firstOrNull;
        if (row == null) return;
        final original = await store.get(row['original_path'] as String);
        if (original == null) throw ConsumeError('Original of document #$id is missing.');
        await scratch.create(recursive: true);
        final local = File(p.join(scratch.path, 'source'));
        await original.copy(local.path);
        final x = await _extract(local, row['mime_type'] as String, scratch);
        final name = id.toString().padLeft(7, '0');
        String? archiveKey = row['archive_path'] as String?;
        String? thumbKey = row['thumbnail_path'] as String?;
        if (x.archive != null) {
          archiveKey = 'archive/$name.pdf';
          await store.put(archiveKey, File(x.archive!));
        }
        if (x.thumbnail != null) {
          thumbKey = 'thumbnails/$name${p.extension(x.thumbnail!)}';
          await store.put(thumbKey, File(x.thumbnail!));
        }
        db.execute(
          'UPDATE documents SET content = ?, archive_path = ?, thumbnail_path = ?, '
          'page_count = COALESCE(?, page_count), modified = ? WHERE id = ?',
          [x.content, archiveKey, thumbKey, x.pages, nowIso(), id],
        );
        _log.info('Dokument #$id neu verarbeitet');
      } catch (e, st) {
        _log.severe('Neuverarbeitung von #$id fehlgeschlagen', e, st);
      } finally {
        if (await scratch.exists()) await scratch.delete(recursive: true);
        done.complete();
      }
    });
    return done.future;
  }
}

String dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
