import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../db.dart';
import '../storage.dart';
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

/// Vorgaben beim Upload (entspricht den Feldern von `post_document`).
class ConsumeOverrides {
  ConsumeOverrides({
    this.title,
    this.created,
    this.correspondent,
    this.documentType,
    this.storagePath,
    this.tags = const [],
    this.archiveSerialNumber,
    this.owner,
  });
  final String? title;
  final DateTime? created;
  final int? correspondent;
  final int? documentType;
  final int? storagePath;
  final List<int> tags;
  final int? archiveSerialNumber;
  final int? owner;
}

class ConsumeError implements Exception {
  ConsumeError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Nimmt Dateien entgegen und verarbeitet sie nacheinander im Hintergrund.
class Consumer {
  Consumer({
    required this.db,
    required this.store,
    required this.tools,
    required this.workDir,
  });

  final Database db;
  final BlobStore store;
  final ExternalTools tools;
  final String workDir;

  Future<void> _queue = Future.value();
  final _uuid = const Uuid();

  /// Legt einen Task an und gibt dessen UUID sofort zurück.
  ///
  /// [file] wird in ein eigenes Arbeitsverzeichnis verschoben bzw. kopiert,
  /// der Aufrufer muss sich danach nicht mehr darum kümmern.
  Future<String> submit(
    File file, {
    required String originalName,
    ConsumeOverrides? overrides,
    bool moveSource = false,
  }) async {
    final taskId = _uuid.v4();
    final staged = File(
      p.join(workDir, 'incoming', '$taskId${p.extension(originalName)}'),
    );
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

    db.execute(
      'INSERT INTO tasks (task_id, task_file_name, date_created, status, owner) '
      'VALUES (?, ?, ?, ?, ?)',
      [taskId, originalName, nowIso(), 'PENDING', overrides?.owner],
    );

    final done = Completer<void>();
    _queue = _queue.then((_) async {
      await _process(
        taskId,
        staged,
        originalName,
        overrides ?? ConsumeOverrides(),
      );
      done.complete();
    });
    _pending[taskId] = done.future;
    unawaited(done.future.whenComplete(() => _pending.remove(taskId)));
    return taskId;
  }

  final _pending = <String, Future<void>>{};

  /// Für Tests: wartet, bis ein Task abgeschlossen ist.
  Future<void> waitFor(String taskId) => _pending[taskId] ?? Future.value();

  void _setTask(String taskId, String status, {String? result, int? document}) {
    final finished = status == 'SUCCESS' || status == 'FAILURE';
    db.execute(
      'UPDATE tasks SET status = ?, result = COALESCE(?, result), '
      'related_document = COALESCE(?, related_document), '
      'date_done = CASE WHEN ? THEN ? ELSE date_done END WHERE task_id = ?',
      [status, result, document, finished ? 1 : 0, nowIso(), taskId],
    );
  }

  Future<void> _process(
    String taskId,
    File staged,
    String originalName,
    ConsumeOverrides o,
  ) async {
    _setTask(taskId, 'STARTED');
    final scratch = Directory(p.join(workDir, 'scratch', taskId));
    try {
      final id = await _consume(staged, originalName, o, scratch);
      _setTask(
        taskId,
        'SUCCESS',
        result: 'Success. New document id $id created',
        document: id,
      );
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

  Future<int> _consume(
    File source,
    String originalName,
    ConsumeOverrides o,
    Directory scratch,
  ) async {
    await scratch.create(recursive: true);
    final bytes = await source.readAsBytes();
    final checksum = md5.convert(bytes).toString();

    final duplicate = db.select(
      'SELECT id, title FROM documents WHERE checksum = ?',
      [checksum],
    );
    if (duplicate.isNotEmpty) {
      final d = duplicate.first;
      throw ConsumeError(
        'Not consuming $originalName: It is a duplicate of '
        '${d['title']} (#${d['id']}).',
      );
    }

    final mime =
        lookupMimeType(
          originalName,
          headerBytes: bytes.take(defaultMagicNumbersMaxLength).toList(),
        ) ??
        'application/octet-stream';
    final ext = supportedMimeTypes[mime];
    if (ext == null) {
      throw ConsumeError(
        'Not consuming $originalName: Unsupported mime type $mime',
      );
    }

    final isPdf = mime == 'application/pdf';
    final isImage = mime.startsWith('image/');
    String content = '';
    String? archive;
    String? thumbnail;
    int? pages;

    if (mime == 'text/plain') {
      content = String.fromCharCodes(bytes);
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
    content = content.replaceAll('\f', '\n').trim();

    final matched = matchContent(db, content);
    final created = o.created ?? findDate(content) ?? DateTime.now();
    final title = (o.title?.trim().isNotEmpty ?? false)
        ? o.title!.trim()
        : p.basenameWithoutExtension(originalName);
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
          content,
          o.correspondent ?? matched.correspondent,
          o.documentType ?? matched.documentType,
          o.storagePath ?? matched.storagePath,
          _dateOnly(created),
          now,
          now,
          o.archiveSerialNumber,
          originalName,
          mime,
          checksum,
          pages,
          o.owner,
        ],
      );
      id = db.lastInsertRowId;
      final name = id.toString().padLeft(7, '0');
      final originalKey = 'originals/$name.$ext';
      final archiveKey = archive == null ? null : 'archive/$name.pdf';
      final thumbKey = thumbnail == null
          ? null
          : 'thumbnails/$name${p.extension(thumbnail)}';
      await store.put(originalKey, source);
      if (archive != null) await store.put(archiveKey!, File(archive));
      if (thumbnail != null) await store.put(thumbKey!, File(thumbnail));
      db.execute(
        'UPDATE documents SET original_path = ?, archive_path = ?, thumbnail_path = ? '
        'WHERE id = ?',
        [originalKey, archiveKey, thumbKey, id],
      );
      final stmt = db.prepare(
        'INSERT OR IGNORE INTO document_tags (document_id, tag_id) '
        'SELECT ?, id FROM tags WHERE id = ?',
      );
      for (final tag in {...o.tags, ...matched.tags}) {
        stmt.execute([id, tag]);
      }
      stmt.close();
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
    return id;
  }
}

String _dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
