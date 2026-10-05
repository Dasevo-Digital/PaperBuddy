import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../file_export.dart';
import '../format.dart';
import '../widgets/custom_field_inputs.dart';
import '../widgets/dialogs.dart';
import '../widgets/document_thumbnail.dart';
import '../widgets/pdf_actions.dart';
import '../widgets/share_links_sheet.dart';
import '../widgets/share_sheet.dart';
import '../widgets/versions_history.dart';
import '../widgets/tag_chip.dart';
import 'document_edit_screen.dart';
import 'document_viewer_screen.dart';
import '../file_kinds.dart';

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

/// Detailansicht eines Dokuments mit Bearbeiten, Ansehen, Teilen und Notizen.
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
  bool _changed = false;
  bool _busy = false;
  String? _error;
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
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

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e is ApiException ? e.message : '$e')),
    );
  }

  void _close() =>
      Navigator.pop(context, _changed ? DocumentUpdated(_doc) : null);

  Future<void> _edit() async {
    final updated = await Navigator.of(context).push<Document>(
      MaterialPageRoute(builder: (_) => DocumentEditScreen(document: _doc)),
    );
    if (updated != null && mounted) {
      setState(() {
        _doc = updated;
        _changed = true;
      });
    }
  }

  void _view() => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => DocumentViewerScreen(document: _doc)),
  );

  Future<void> _share(BuildContext anchor) async {
    setState(() => _busy = true);
    try {
      final file = await AppScope.read(context).client.downloadFile(_doc.id);
      if (!anchor.mounted) return;
      final name = file.fileName.contains('.')
          ? file.fileName
          : '${_doc.title}.pdf';
      await exportFile(
        anchor,
        Uint8List.fromList(file.bytes),
        name,
        file.mimeType,
      );
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeFromInbox() async {
    final state = AppScope.read(context);
    final inbox = {
      for (final t in state.tags.values)
        if (t.isInboxTag) t.id,
    };
    try {
      final updated = await state.client.updateDocument(_doc.id, {
        'tags': _doc.tags.where((t) => !inbox.contains(t)).toList(),
      });
      state.refreshLabels().ignore();
      if (mounted) {
        setState(() {
          _doc = updated;
          _changed = true;
        });
      }
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _addNote() async {
    final text = _note.text.trim();
    if (text.isEmpty) return;
    try {
      final notes = await AppScope.read(context).client.addNote(_doc.id, text);
      _note.clear();
      if (mounted) setState(() => _doc = _withNotes(notes));
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _deleteNote(Note note) async {
    try {
      final client = AppScope.read(context).client;
      await client.deleteNote(_doc.id, note.id);
      final doc = await client.document(_doc.id);
      if (mounted) setState(() => _doc = doc);
    } catch (e) {
      _showError(e);
    }
  }

  Document _withNotes(List<Note> notes) => Document(
    id: _doc.id,
    title: _doc.title,
    content: _doc.content,
    tags: _doc.tags,
    created: _doc.created,
    correspondent: _doc.correspondent,
    documentType: _doc.documentType,
    storagePath: _doc.storagePath,
    added: _doc.added,
    modified: _doc.modified,
    archiveSerialNumber: _doc.archiveSerialNumber,
    originalFileName: _doc.originalFileName,
    archivedFileName: _doc.archivedFileName,
    mimeType: _doc.mimeType,
    pageCount: _doc.pageCount,
    notes: notes,
    owner: _doc.owner,
    userCanChange: _doc.userCanChange,
    customFields: _doc.customFields,
    versions: _doc.versions,
  );

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Dokument löschen?'),
        content: Text(
          '„${_doc.title}“ wird in den Papierkorb des Servers verschoben.',
        ),
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
    } catch (e) {
      _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final user = state.client.user;
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final tags = [for (final id in _doc.tags) ?state.tags[id]];
    final inInbox = tags.any((t) => t.isInboxTag);
    final canChange = user.can('change', 'document') && _doc.userCanChange;

    final preview = Material(
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _view,
        child: AspectRatio(
          aspectRatio: 0.72,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DocumentThumbnail(
                documentId: _doc.id,
                mimeType: _doc.mimeType,
                fit: BoxFit.contain,
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: FilledButton.tonalIcon(
                  onPressed: _view,
                  icon: const Icon(LucideIcons.maximize2, size: 16),
                  label: const Text('Öffnen'),
                ),
              ),
            ],
          ),
        ),
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
        if (inInbox && canChange) ...[
          FilledButton.tonalIcon(
            onPressed: _removeFromInbox,
            icon: const Icon(LucideIcons.inbox),
            label: const Text('Aus dem Posteingang entfernen'),
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
          LucideIcons.folderTree,
          'Speicherpfad',
          state.storagePaths[_doc.storagePath]?.name,
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
        if (_doc.mimeType != null)
          _Field(
            FileKinds.icon(_doc.mimeType),
            'Dateityp',
            FileKinds.describe(_doc.mimeType!),
          ),
        if (_doc.pageCount != null)
          _Field(LucideIcons.layers, 'Seiten', '${_doc.pageCount}'),
        _Field(
          LucideIcons.userRound,
          'Eigentümer',
          _doc.owner == null
              ? 'Alle'
              : (state.users[_doc.owner]?.displayName ??
                    (_doc.owner == user.id ? 'Ich' : '#${_doc.owner}')),
        ),
        for (final v in _doc.customFields)
          _Field(
            LucideIcons.textCursorInput,
            state.customFields[v.field]?.name ?? 'Feld ${v.field}',
            formatCustomValue(state.customFields[v.field], v.value),
          ),
        const SizedBox(height: 20),
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
            trailing: user.can('delete', 'note')
                ? IconButton(
                    tooltip: 'Notiz löschen',
                    icon: const Icon(LucideIcons.x),
                    onPressed: () => _deleteNote(n),
                  )
                : null,
          ),
        if (user.can('add', 'note'))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _note,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _addNote(),
              decoration: InputDecoration(
                hintText: 'Notiz hinzufügen',
                suffixIcon: IconButton(
                  tooltip: 'Notiz speichern',
                  icon: const Icon(LucideIcons.send),
                  onPressed: _addNote,
                ),
              ),
            ),
          ),
        const SizedBox(height: 20),
        VersionsSection(
          document: _doc,
          onChanged: () {
            _changed = true;
            _load();
          },
        ),
        HistorySection(key: ValueKey(_doc.modified), documentId: _doc.id),
        const SizedBox(height: 20),
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _close),
          actions: [
            if (canChange)
              IconButton(
                tooltip: 'Bearbeiten',
                icon: const Icon(LucideIcons.pencil),
                onPressed: _edit,
              ),
            Builder(
              builder: (anchor) => IconButton(
                tooltip: 'Teilen oder speichern',
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(LucideIcons.share),
                onPressed: _busy ? null : () => _share(anchor),
              ),
            ),
            if (canChange)
              PdfActionsMenu(
                document: _doc,
                onDone: () {
                  final state = AppScope.read(context);
                  state.thumbnails.evict(_doc.id);
                  _changed = true;
                  _load();
                },
              ),
            if (user.can('view', 'sharelink'))
              IconButton(
                tooltip: 'Freigabelinks',
                icon: const Icon(LucideIcons.link),
                onPressed: () => showShareLinksSheet(context, _doc),
              ),
            if (canChange)
              IconButton(
                tooltip: 'Freigaben',
                icon: const Icon(LucideIcons.userPlus),
                onPressed: () async {
                  final updated = await showShareSheet(context, _doc);
                  if (updated != null && mounted) {
                    setState(() {
                      _doc = updated;
                      _changed = true;
                    });
                    showInfo(this.context, 'Freigaben gespeichert');
                  }
                },
              ),
            if (user.can('delete', 'document'))
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
