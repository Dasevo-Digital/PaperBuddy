import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../format.dart';
import '../screens/document_viewer_screen.dart';
import 'dialogs.dart';

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
      allowedExtensions: const [
        'pdf',
        'png',
        'jpg',
        'jpeg',
        'tif',
        'tiff',
        'webp',
        'txt',
      ],
    );
    if (picked.isEmpty || !context.mounted) return;
    final file = picked.first;
    final bytes = await file.readAsBytes();
    if (!context.mounted) return;
    final label = await askText(
      context,
      title: 'Neue Version',
      label: 'Bezeichnung (optional)',
      hint: 'z. B. unterschrieben',
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
    showInfo(context, 'Neue Version wird verarbeitet …');
    final result = await guarded(context, () => state.client.waitForTask(task));
    if (!context.mounted || result == null) return;
    if (result.status == TaskStatus.success) {
      state.thumbnails.evict(document.id);
      showInfo(context, 'Neue Version gespeichert');
      onChanged();
    } else {
      showError(context, result.result ?? 'Verarbeitung fehlgeschlagen');
    }
  }

  Future<void> _delete(BuildContext context, DocumentVersion v) async {
    final ok = await confirm(
      context,
      title: 'Version entfernen?',
      action: 'Entfernen',
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
              child: Text('Versionen', style: theme.textTheme.titleMedium),
            ),
            if (canChange)
              TextButton.icon(
                onPressed: () => _upload(context),
                icon: const Icon(LucideIcons.filePlus2),
                label: const Text('Neue Version'),
              ),
          ],
        ),
        if (versions.isEmpty)
          Text(
            'Nur die ursprüngliche Fassung',
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
                          ? 'Ursprüngliche Fassung'
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
                      tooltip: 'Version entfernen',
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

  static const _labels = {
    'title': 'Titel',
    'correspondent': 'Korrespondent',
    'document_type': 'Dokumenttyp',
    'storage_path': 'Speicherpfad',
    'created': 'Belegdatum',
    'archive_serial_number': 'Archivnummer',
    'owner': 'Eigentümer',
    'checksum': 'Datei',
    'original_filename': 'Dateiname',
    'content': 'Inhalt',
    'deleted_at': 'Papierkorb',
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
        if (key == 'deleted_at') return 'gelöscht';
        return '$v';
      }

      if (key == 'version') return 'Neue Version: ${show(change[1])}';
      if (key == 'deleted_at') {
        return change[1] == null || change[1] == 'null'
            ? 'Wiederhergestellt'
            : 'In den Papierkorb';
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
      title: Text('Verlauf', style: theme.textTheme.titleMedium),
      onExpansionChanged: (open) {
        if (open && _entries == null) {
          setState(() => _entries = state.client.history(widget.documentId));
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
                    ? 'Der Server führt keinen Verlauf.'
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
            if (entries.isEmpty) return const Text('Noch keine Einträge');
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
                          ? 'Angelegt'
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
