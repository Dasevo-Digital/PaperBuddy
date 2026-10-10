import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../format.dart';
import '../screens/document_viewer_screen.dart';
import 'dialogs.dart';
import '../file_kinds.dart';
import '../l10n.dart';

/// Fassungen eines Dokuments: ansehen, neue hochladen, alte entfernen.
class VersionsSection extends StatelessWidget {
  const VersionsSection({
    super.key,
    required this.document,
    required this.onChanged,
  });

  final Document document;
  final VoidCallback onChanged;

  Future<void> _upload(BuildContext context) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: FileKinds.uploadExtensions,
    );
    if (picked.isEmpty || !context.mounted) return;
    final file = picked.first;
    final bytes = await file.readAsBytes();
    if (!context.mounted) return;
    final label = await askText(
      context,
      title: tr.newVersion,
      label: tr.labelOptional,
      hint: tr.eGSigned,
    );
    if (!context.mounted) return;
    final state = AppScope.read(context);
    final task = await guarded(
      context,
      () => state.client.uploadVersion(
        document.id,
        bytes,
        file.name,
        label: label,
      ),
    );
    if (task == null || !context.mounted) return;
    showInfo(context, tr.newVersionIsBeingProcessed);
    final result = await guarded(context, () => state.client.waitForTask(task));
    if (!context.mounted || result == null) return;
    if (result.status == TaskStatus.success) {
      state.thumbnails.evict(document.id);
      showInfo(context, tr.newVersionSaved);
      onChanged();
    } else {
      showError(context, result.result ?? tr.processingFailed);
    }
  }

  Future<void> _delete(BuildContext context, DocumentVersion v) async {
    final ok = await confirm(
      context,
      title: tr.removeVersionQuestion,
      action: tr.remove,
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await guarded(
      context,
      () => AppScope.read(context).client.deleteVersion(document.id, v.id),
    );
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canChange =
        document.userCanChange &&
        AppScope.of(context).client.user.can('change', 'document');
    final versions = document.versions.reversed.toList();
    final current = versions.isEmpty ? null : versions.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(tr.versions, style: theme.textTheme.titleMedium),
            ),
            if (canChange)
              TextButton.icon(
                onPressed: () => _upload(context),
                icon: const Icon(LucideIcons.filePlus2),
                label: Text(tr.newVersion),
              ),
          ],
        ),
        if (versions.isEmpty)
          Text(
            tr.onlyTheOriginalVersion,
            style: theme.textTheme.bodyMedium,
          )
        else
          for (final (i, v) in versions.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                v == current ? LucideIcons.fileCheck : LucideIcons.fileClock,
              ),
              title: Text(
                [
                  v.label ??
                      (v.isRoot
                          ? tr.originalVersion
                          : 'Version ${versions.length - i}'),
                  if (v == current) '(aktuell)',
                ].join(' '),
              ),
              subtitle: v.added == null ? null : Text(formatDayTime(v.added!)),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DocumentViewerScreen(
                    document: document,
                    version: v == current ? null : v.id,
                  ),
                ),
              ),
              trailing: canChange && v != current
                  ? IconButton(
                      tooltip: tr.removeVersion,
                      icon: const Icon(LucideIcons.trash2),
                      onPressed: () => _delete(context, v),
                    )
                  : null,
            ),
      ],
    );
  }
}

/// Änderungsverlauf, auf Wunsch aufgeklappt.
class HistorySection extends StatefulWidget {
  const HistorySection({super.key, required this.documentId});
  final int documentId;

  @override
  State<HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends State<HistorySection> {
  Future<List<HistoryEntry>>? _entries;

  static Map<String, String> get _labels => {
    'title': tr.title,
    'correspondent': tr.correspondent,
    'document_type': tr.documentType,
    'storage_path': tr.storagePath,
    'created': tr.documentDate,
    'archive_serial_number': tr.archiveSerialNumber,
    'owner': tr.owner,
    'checksum': tr.file,
    'original_filename': tr.fileName,
    'content': tr.content,
    'deleted_at': tr.trash,
    'tags': 'Tags',
    'tags_removed': 'Tags',
    'version': 'Version',
  };

  String _describe(AppState state, String key, Object? change) {
    final label = key.startsWith('custom_field:')
        ? key.substring(13)
        : (_labels[key] ?? key);
    if (change is Map) {
      final objects = (change['objects'] as List? ?? const []).join(', ');
      return '$label ${change['operation'] == 'remove' ? 'entfernt' : 'hinzugefügt'}: $objects';
    }
    if (change is List && change.length == 2) {
      String show(Object? v) {
        if (v == null || v == 'null') return '–';
        final id = int.tryParse('$v');
        if (id != null) {
          final name = switch (key) {
            'correspondent' => state.correspondents[id]?.name,
            'document_type' => state.documentTypes[id]?.name,
            'storage_path' => state.storagePaths[id]?.name,
            'owner' => state.users[id]?.displayName,
            _ => null,
          };
          if (name != null) return name;
        }
        if (key == 'checksum') return '${'$v'.substring(0, 8)}…';
        if (key == 'deleted_at') return tr.deleted;
        return '$v';
      }

      if (key == 'version') return tr.newVersionNamed(show(change[1]));
      if (key == 'deleted_at') {
        return change[1] == null || change[1] == 'null'
            ? tr.restored
            : tr.moveToTrash;
      }
      return '$label: ${show(change[0])} → ${show(change[1])}';
    }
    return label;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(tr.history, style: theme.textTheme.titleMedium),
      onExpansionChanged: (open) {
        if (open && _entries == null) {
          setState(() {
            _entries = state.client.history(widget.documentId);
          });
        }
      },
      children: [
        FutureBuilder<List<HistoryEntry>>(
          future: _entries,
          builder: (context, snap) {
            if (snap.hasError) {
              final e = snap.error;
              return Text(
                e is ApiException && e.isNotFound
                    ? tr.theServerKeepsNoHistory
                    : '$e',
              );
            }
            final entries = snap.data;
            if (entries == null) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: LinearProgressIndicator(),
              );
            }
            if (entries.isEmpty) return Text(tr.noEntriesYet);
            return Column(
              children: [
                for (final e in entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      e.action == 'create'
                          ? LucideIcons.filePlus
                          : LucideIcons.history,
                    ),
                    title: Text(
                      e.action == 'create'
                          ? tr.created
                          : e.changes.entries
                                .map((c) => _describe(state, c.key, c.value))
                                .join('\n'),
                    ),
                    subtitle: Text(
                      [
                        if (e.timestamp != null) formatDayTime(e.timestamp!),
                        e.actor ?? 'automatisch',
                      ].join(' · '),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Wer das Dokument angesehen, heruntergeladen oder über einen Freigabelink
/// abgerufen hat (PaperBuddy-Erweiterung).
class AccessLogSection extends StatefulWidget {
  const AccessLogSection({super.key, required this.documentId});

  final int documentId;

  @override
  State<AccessLogSection> createState() => _AccessLogSectionState();
}

class _AccessLogSectionState extends State<AccessLogSection> {
  Future<List<AccessEntry>>? _entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(tr.accessLog, style: theme.textTheme.titleMedium),
      onExpansionChanged: (open) {
        if (open && _entries == null) {
          setState(() {
            _entries = AppScope.read(
              context,
            ).client.accessLog(widget.documentId);
          });
        }
      },
      children: [
        FutureBuilder<List<AccessEntry>>(
          future: _entries,
          builder: (context, snap) {
            if (snap.hasError) {
              final e = snap.error;
              return Text(switch (e) {
                ApiException(isNotFound: true) =>
                  tr.theServerDoesNotLog,
                ApiException(statusCode: 403) =>
                  tr.visibleToTheOwnerOnly,
                _ => '$e',
              });
            }
            final entries = snap.data;
            if (entries == null) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: LinearProgressIndicator(),
              );
            }
            if (entries.isEmpty) return Text(tr.noAccessYet);
            return Column(
              children: [
                for (final e in entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(switch (e.action) {
                      'download' => LucideIcons.download,
                      'share' => LucideIcons.link,
                      _ => LucideIcons.eye,
                    }),
                    title: Text(switch (e.action) {
                      'download' => tr.downloaded,
                      'share' => tr.openedViaShareLink,
                      _ => tr.viewed,
                    }),
                    subtitle: Text(
                      [
                        if (e.timestamp != null) formatDayTime(e.timestamp!),
                        ?(e.actor ?? e.address),
                      ].join(' · '),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
