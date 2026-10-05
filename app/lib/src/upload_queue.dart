import 'package:flutter/foundation.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

enum UploadState { uploading, processing, done, failed }

/// Eine Datei samt optionaler Metadaten für `post_document`.
class UploadRequest {
  const UploadRequest(
    this.fileName,
    this.bytes, {
    this.title,
    this.created,
    this.correspondent,
    this.documentType,
    this.storagePath,
    this.tags = const [],
    this.archiveSerialNumber,
  });

  final String fileName;
  final Uint8List bytes;
  final String? title;
  final DateTime? created;
  final int? correspondent;
  final int? documentType;
  final int? storagePath;
  final List<int> tags;
  final int? archiveSerialNumber;
}

class UploadJob {
  UploadJob(this.fileName);
  final String fileName;
  UploadState state = UploadState.uploading;
  String? message;
  int? documentId;

  bool get finished => state == UploadState.done || state == UploadState.failed;
}

/// Lädt Dateien nacheinander hoch und verfolgt die Verarbeitung auf dem Server.
class UploadQueue extends ChangeNotifier {
  UploadQueue({required this.onDocumentAdded});

  /// Wird nach jedem erfolgreich verarbeiteten Dokument aufgerufen.
  final VoidCallback onDocumentAdded;
  final List<UploadJob> jobs = [];

  bool get busy => jobs.any((j) => !j.finished);
  int get failedCount =>
      jobs.where((j) => j.state == UploadState.failed).length;

  Future<void> add(PaperlessClient client, List<UploadRequest> requests) async {
    final batch = [
      for (final r in requests) (UploadJob(r.title ?? r.fileName), r),
    ];
    jobs.addAll(batch.map((b) => b.$1));
    notifyListeners();
    for (final (job, request) in batch) {
      await _run(client, job, request);
    }
  }

  Future<void> _run(
    PaperlessClient client,
    UploadJob job,
    UploadRequest r,
  ) async {
    try {
      final taskId = await client.uploadDocument(
        r.bytes,
        r.fileName,
        title: r.title,
        created: r.created,
        correspondent: r.correspondent,
        documentType: r.documentType,
        storagePath: r.storagePath,
        tags: r.tags,
        archiveSerialNumber: r.archiveSerialNumber,
      );
      job.state = UploadState.processing;
      notifyListeners();
      final task = await client.waitForTask(taskId);
      if (task.status == TaskStatus.success) {
        job.state = UploadState.done;
        job.documentId = task.documentId;
        onDocumentAdded();
      } else {
        job.state = UploadState.failed;
        job.message = _readableResult(task.result);
      }
    } on ApiException catch (e) {
      job.state = UploadState.failed;
      job.message = e.message;
    }
    notifyListeners();
  }

  /// Verfolgt einen bereits gestarteten Task (z. B. Netzwerkscan).
  Future<void> trackTask(
    PaperlessClient client,
    String taskId,
    String label,
  ) async {
    final job = UploadJob(label)..state = UploadState.processing;
    jobs.add(job);
    notifyListeners();
    try {
      final task = await client.waitForTask(taskId);
      if (task.status == TaskStatus.success) {
        job.state = UploadState.done;
        job.documentId = task.documentId;
        onDocumentAdded();
      } else {
        job.state = UploadState.failed;
        job.message = _readableResult(task.result);
      }
    } on ApiException catch (e) {
      job.state = UploadState.failed;
      job.message = e.message;
    }
    notifyListeners();
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.finished);
    notifyListeners();
  }

  static String _readableResult(String? result) {
    if (result == null) return 'Verarbeitung fehlgeschlagen';
    if (result.contains('duplicate')) {
      return 'Dieses Dokument ist bereits vorhanden.';
    }
    if (result.contains('Unsupported mime type')) {
      return 'Dateityp wird nicht unterstützt.';
    }
    return result;
  }
}
