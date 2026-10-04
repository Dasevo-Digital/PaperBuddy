import 'package:flutter/foundation.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

enum UploadState { uploading, processing, done, failed }

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

  Future<void> add(
    PaperlessClient client,
    List<({String name, Uint8List bytes})> files,
  ) async {
    final batch = [for (final f in files) (UploadJob(f.name), f.bytes)];
    jobs.addAll(batch.map((b) => b.$1));
    notifyListeners();
    for (final (job, bytes) in batch) {
      await _run(client, job, bytes);
    }
  }

  Future<void> _run(
    PaperlessClient client,
    UploadJob job,
    Uint8List bytes,
  ) async {
    try {
      final taskId = await client.uploadDocument(bytes, job.fileName);
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
