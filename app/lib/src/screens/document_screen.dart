import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/document_thumbnail.dart';
import '../widgets/tag_chip.dart';

/// Was die Detailansicht an die Liste zurückmeldet.
sealed class DocumentScreenResult {}

class DocumentDeleted extends DocumentScreenResult {
  DocumentDeleted(this.id);
  final int id;
}

class DocumentUpdated extends DocumentScreenResult {
  DocumentUpdated(this.document);
  final Document document;
}

/// Detailansicht eines Dokuments. Bearbeiten folgt in einem eigenen Schritt.
class DocumentScreen extends StatefulWidget {
  const DocumentScreen({super.key, required this.document});

  /// Eintrag aus der Liste; der Inhalt ist dort gekürzt und wird nachgeladen.
  final Document document;

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends State<DocumentScreen> {
  late Document _doc = widget.document;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await AppScope.read(
        context,
      ).client.document(widget.document.id);
      if (mounted) setState(() => _doc = doc);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Dokument löschen?'),
        content: Text('„${_doc.title}“ wird endgültig vom Server gelöscht.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final state = AppScope.read(context);
    try {
      await state.client.deleteDocument(_doc.id);
      state.thumbnails.evict(_doc.id);
      state.refreshLabels().ignore();
      if (mounted) Navigator.pop(context, DocumentDeleted(_doc.id));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final tags = [for (final id in _doc.tags) ?state.tags[id]];

    final preview = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 0.72,
        child: DocumentThumbnail(documentId: _doc.id, fit: BoxFit.contain),
      ),
    );

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_doc.title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        if (tags.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final t in tags) TagChip(tag: t, dense: false)],
          ),
          const SizedBox(height: 12),
        ],
        _Field(LucideIcons.calendar, 'Belegdatum', formatDay(_doc.created)),
        _Field(
          LucideIcons.user,
          'Korrespondent',
          state.correspondents[_doc.correspondent]?.name,
        ),
        _Field(
          LucideIcons.fileType,
          'Dokumenttyp',
          state.documentTypes[_doc.documentType]?.name,
        ),
        _Field(
          LucideIcons.hash,
          'Archivnummer',
          _doc.archiveSerialNumber?.toString(),
        ),
        _Field(
          LucideIcons.filePlus,
          'Hinzugefügt',
          _doc.added == null ? null : formatDayTime(_doc.added!),
        ),
        _Field(LucideIcons.paperclip, 'Originaldatei', _doc.originalFileName),
        if (_doc.pageCount != null)
          _Field(LucideIcons.layers, 'Seiten', '${_doc.pageCount}'),
        if (_doc.notes.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Notizen', style: theme.textTheme.titleMedium),
          for (final n in _doc.notes)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(LucideIcons.stickyNote),
              title: Text(n.note),
              subtitle: Text(
                [
                  ?n.username,
                  if (n.created != null) formatDayTime(n.created!),
                ].join(' · '),
              ),
            ),
        ],
        const SizedBox(height: 16),
        Text('Inhalt', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_loading)
          const LinearProgressIndicator()
        else if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error))
        else
          SelectableText(
            _doc.content.isEmpty ? 'Kein Text erkannt.' : _doc.content,
            style: theme.textTheme.bodyMedium,
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        actions: [
          if (state.client.user.can('delete', 'document'))
            IconButton(
              tooltip: 'Löschen',
              icon: const Icon(LucideIcons.trash2),
              onPressed: _delete,
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 360, child: preview),
                        const SizedBox(width: 32),
                        Expanded(child: details),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(child: SizedBox(width: 240, child: preview)),
                        const SizedBox(height: 20),
                        details,
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.icon, this.label, this.value);
  final IconData icon;
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(value ?? '–', style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
