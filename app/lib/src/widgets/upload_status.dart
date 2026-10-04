import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../upload_queue.dart';

/// Leiste unter der Liste, solange Uploads laufen oder Ergebnisse offen sind.
class UploadStatusBar extends StatelessWidget {
  const UploadStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final uploads = AppScope.of(context).uploads;
    return ListenableBuilder(
      listenable: uploads,
      builder: (context, _) {
        if (uploads.jobs.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final running = uploads.jobs.where((j) => !j.finished).length;
        final failed = uploads.failedCount;
        final done = uploads.jobs
            .where((j) => j.state == UploadState.done)
            .length;
        final text = running > 0
            ? (running == 1
                  ? '1 Datei wird verarbeitet …'
                  : '$running Dateien werden verarbeitet …')
            : [
                if (done > 0)
                  done == 1
                      ? '1 Dokument hinzugefügt'
                      : '$done Dokumente hinzugefügt',
                if (failed > 0) '$failed fehlgeschlagen',
              ].join(', ');
        return Material(
          color: failed > 0 && running == 0
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.secondaryContainer,
          child: SafeArea(
            top: false,
            child: ListTile(
              leading: running > 0
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      failed > 0
                          ? LucideIcons.circleAlert
                          : LucideIcons.circleCheck,
                    ),
              title: Text(text),
              onTap: () => _showDetails(context, uploads),
              trailing: running == 0
                  ? IconButton(
                      tooltip: 'Ausblenden',
                      icon: const Icon(LucideIcons.x),
                      onPressed: uploads.clearFinished,
                    )
                  : null,
            ),
          ),
        );
      },
    );
  }

  void _showDetails(BuildContext context, UploadQueue uploads) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListenableBuilder(
        listenable: uploads,
        builder: (context, _) => ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            for (final job in uploads.jobs.reversed)
              ListTile(
                leading: switch (job.state) {
                  UploadState.uploading ||
                  UploadState.processing => const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  UploadState.done => const Icon(LucideIcons.circleCheck),
                  UploadState.failed => Icon(
                    LucideIcons.circleAlert,
                    color: Theme.of(context).colorScheme.error,
                  ),
                },
                title: Text(
                  job.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(switch (job.state) {
                  UploadState.uploading => 'Wird hochgeladen …',
                  UploadState.processing => 'Texterkennung läuft …',
                  UploadState.done => 'Hinzugefügt',
                  UploadState.failed => job.message ?? 'Fehlgeschlagen',
                }),
              ),
          ],
        ),
      ),
    );
  }
}
