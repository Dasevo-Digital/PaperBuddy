import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'upload_queue.dart';
import 'l10n.dart';

enum NoticeKind {
  running,
  success,
  failure,

  /// Fällige Frist an einem Dokument.
  reminder,
}

/// Eine Meldung in der Benachrichtigungszentrale: ein Upload aus der App
/// oder ein Import auf dem Server (Eingangsordner, Mail, Scanner).
@immutable
class Notice {
  const Notice({
    required this.key,
    required this.kind,
    required this.title,
    required this.time,
    this.detail,
    this.documentId,
    this.taskDbId,
    this.job,
    this.reminderId,
  });

  final String key;
  final NoticeKind kind;
  final String title;
  final String? detail;
  final DateTime time;
  final int? documentId;
  final int? taskDbId;

  /// Zugehöriger Upload aus dieser App, falls es einer ist.
  final UploadJob? job;

  /// Bei Fristen: deren ID.
  final int? reminderId;
}

/// Sammelt Meldungen zu Uploads und Server-Tasks. Neue Ergebnisse meldet
/// [onPopup] kurz; die Liste bleibt, bis sie entfernt wird. Entfernen
/// markiert den Task auch auf dem Server als gelesen, wie in Paperless-ngx.
class NotificationCenter extends ChangeNotifier {
  NotificationCenter({
    required this.uploads,
    required this.onDocumentAdded,
    required this.loadSeen,
    required this.saveSeen,
  }) {
    uploads.addListener(_onUploads);
  }

  final UploadQueue uploads;

  /// Ein Dokument ist auf dem Server neu hinzugekommen (z. B. per Mail).
  final VoidCallback onDocumentAdded;
  final DateTime? Function() loadSeen;
  final Future<void> Function(DateTime) saveSeen;

  /// Wird für jede neu abgeschlossene Meldung einmal aufgerufen.
  void Function(Notice notice)? onPopup;

  static const pollInterval = Duration(seconds: 30);
  static const fastPollInterval = Duration(seconds: 5);
  static const maxServerNotices = 50;

  PaperlessClient? _client;
  Timer? _timer;
  bool _polling = false;

  /// Server darf keine Tasks zeigen (fehlendes Recht): nur lokale Uploads.
  bool _serverDisabled = false;

  final _serverTasks = <String, ConsumeTask>{};

  /// Fällige offene Fristen; bleiben, bis sie erledigt oder entfernt sind.
  final _reminders = <int, Reminder>{};

  /// Server ohne Fristen (z. B. Paperless-ngx).
  bool _remindersUnsupported = false;
  final _dismissed = <String>{};
  final _announced = <String>{};
  DateTime _seen = DateTime.now();

  List<Notice> get notices {
    final byKey = <String, Notice>{};
    for (final t in _serverTasks.values) {
      final n = _fromTask(t);
      byKey[n.key] = n;
    }
    for (final job in uploads.jobs) {
      final n = _fromJob(job);
      byKey[n.key] = n;
    }
    for (final r in _reminders.values) {
      final n = _fromReminder(r);
      byKey[n.key] = n;
    }
    final list = [
      for (final n in byKey.values)
        if (!_dismissed.contains(n.key)) n,
    ]..sort((a, b) => b.time.compareTo(a.time));
    return list;
  }

  /// Ungelesene Ergebnisse (laufende zählen nicht); fällige Fristen zählen,
  /// bis sie erledigt oder entfernt sind.
  int get unread => notices.where(isUnread).length;

  bool get hasRunning => notices.any((n) => n.kind == NoticeKind.running);

  bool isUnread(Notice n) =>
      n.kind == NoticeKind.reminder ||
      (n.kind != NoticeKind.running && n.time.isAfter(_seen));

  void start(PaperlessClient client) {
    stop();
    _client = client;
    _serverDisabled = !client.user.can('view', 'paperlesstask');
    // Beim ersten Start gilt alles Vorhandene als gelesen.
    _seen = loadSeen() ?? DateTime.now();
    if (loadSeen() == null) saveSeen(_seen).ignore();
    refresh(initial: true).ignore();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _client = null;
    _serverTasks.clear();
    _reminders.clear();
    _remindersUnsupported = false;
    _dismissed.clear();
    _announced.clear();
    notifyListeners();
  }

  /// Fragt die Server-Tasks ab und plant die nächste Abfrage.
  Future<void> refresh({bool initial = false}) async {
    final client = _client;
    if (client == null || _polling) return;
    _polling = true;
    try {
      if (!_serverDisabled) {
        final tasks = await client.tasks(unacknowledgedOnly: true);
        tasks.sort(
          (a, b) =>
              (b.created ?? DateTime(0)).compareTo(a.created ?? DateTime(0)),
        );
        final fresh = {
          for (final t in tasks.take(maxServerNotices)) t.taskId: t,
        };
        var added = false;
        for (final t in fresh.values) {
          final before = _serverTasks[t.taskId];
          final ownJob = uploads.jobs.any((j) => j.taskId == t.taskId);
          if (!initial &&
              !ownJob &&
              t.isDone &&
              (before == null || !before.isDone)) {
            if (t.status == TaskStatus.success) added = true;
            _announce(_fromTask(t));
          }
          if (initial && t.isDone) _announced.add(t.taskId);
        }
        _serverTasks
          ..clear()
          ..addAll(fresh);
        if (added) onDocumentAdded();
      }
    } on ApiException catch (e) {
      if (e.isUnauthorized) _serverDisabled = true;
    } catch (_) {
      // Netzwerk kurz weg: beim nächsten Mal erneut.
    }
    await _refreshReminders(client);
    _polling = false;
    notifyListeners();
    _schedule();
  }

  Future<void> _refreshReminders(PaperlessClient client) async {
    if (_remindersUnsupported) return;
    try {
      final due = await client.reminders(
        done: false,
        dueBefore: DateTime.now(),
      );
      _reminders
        ..clear()
        ..addEntries(due.map((r) => MapEntry(r.id, r)));
      // Einmal je Sitzung kurz darauf hinweisen.
      for (final r in due) {
        _announce(_fromReminder(r));
      }
    } on ApiException catch (e) {
      if (e.isUnauthorized || e.isNotFound) _remindersUnsupported = true;
    } catch (_) {}
  }

  bool _paused = false;

  /// App im Hintergrund: keine Abfragen.
  void pause() {
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Zurück im Vordergrund: sofort abgleichen und weiter abfragen.
  void resume() {
    if (!_paused) return;
    _paused = false;
    refresh().ignore();
  }

  void _schedule() {
    _timer?.cancel();
    if (_paused) return;
    if (_client == null || (_serverDisabled && _remindersUnsupported)) return;
    _timer = Timer(hasRunning ? fastPollInterval : pollInterval, refresh);
  }

  /// Popup öffnet die Liste: alles bis jetzt gilt als gelesen.
  void markAllSeen() {
    _seen = DateTime.now();
    saveSeen(_seen).ignore();
    notifyListeners();
  }

  Future<void> dismiss(Notice n) => _dismissAll([n]);

  /// Entfernt alle abgeschlossenen Meldungen.
  Future<void> clearFinished() =>
      _dismissAll(notices.where((n) => n.kind != NoticeKind.running).toList());

  Future<void> _dismissAll(List<Notice> list) async {
    final ids = <int>[];
    for (final n in list) {
      _dismissed.add(n.key);
      if (n.job != null) uploads.remove(n.job!);
      _serverTasks.remove(n.key);
      if (n.kind == NoticeKind.reminder) _reminders.remove(n.reminderId);
      if (n.taskDbId != null) ids.add(n.taskDbId!);
    }
    notifyListeners();
    final client = _client;
    if (ids.isEmpty || client == null || _serverDisabled) return;
    try {
      await client.acknowledgeTasks(ids);
    } on ApiException {
      // Fehlendes Recht: dann bleibt es nur lokal ausgeblendet.
    }
  }

  void _onUploads() {
    for (final job in uploads.jobs) {
      if (job.finished) _announce(_fromJob(job));
    }
    notifyListeners();
    if (hasRunning && _timer == null) _schedule();
  }

  void _announce(Notice n) {
    if (n.kind == NoticeKind.running || !_announced.add(n.key)) return;
    onPopup?.call(n);
  }

  Notice _fromJob(UploadJob job) => Notice(
    key: job.taskId ?? 'upload:${identityHashCode(job)}',
    kind: switch (job.state) {
      UploadState.uploading || UploadState.processing => NoticeKind.running,
      UploadState.done => NoticeKind.success,
      UploadState.failed => NoticeKind.failure,
    },
    title: job.fileName,
    detail: switch (job.state) {
      UploadState.uploading => tr.uploading,
      UploadState.processing => tr.recognizingText,
      UploadState.done => tr.documentAdded,
      UploadState.failed => job.message ?? tr.failed,
    },
    time: job.finishedAt ?? job.started,
    documentId: job.documentId,
    taskDbId: job.taskDbId ?? _serverTasks[job.taskId]?.id,
    job: job,
  );

  Notice _fromReminder(Reminder r) {
    final d = r.due;
    final date = '${d.day}.${d.month}.${d.year}';
    return Notice(
      key: 'reminder:${r.id}',
      kind: NoticeKind.reminder,
      title: r.note.isEmpty ? tr.deadlineTitled(r.documentTitle) : r.note,
      detail: r.note.isEmpty
          ? tr.dueDate(date)
          : tr.dueDateWithTitle(date, r.documentTitle),
      time: DateTime(d.year, d.month, d.day),
      documentId: r.document,
      reminderId: r.id,
    );
  }

  Notice _fromTask(ConsumeTask t) => Notice(
    key: t.taskId,
    kind: switch (t.status) {
      TaskStatus.success => NoticeKind.success,
      TaskStatus.failure => NoticeKind.failure,
      _ => NoticeKind.running,
    },
    title: t.fileName ?? tr.import,
    detail: switch (t.status) {
      TaskStatus.success => tr.documentAdded,
      TaskStatus.failure => UploadQueue.readableResult(t.result),
      TaskStatus.pending => tr.waitingForProcessing,
      _ => tr.processingRunning,
    },
    time: t.done ?? t.created ?? DateTime.now(),
    documentId: t.documentId,
    taskDbId: t.id,
  );

  @override
  void dispose() {
    _timer?.cancel();
    uploads.removeListener(_onUploads);
    super.dispose();
  }
}
