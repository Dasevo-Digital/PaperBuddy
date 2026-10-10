import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../format.dart';
import '../scan/scan_service.dart';
import '../upload_queue.dart';
import '../widgets/label_pickers.dart';

/// Neues Dokument hochladen: gescannte Seiten (werden zu einem PDF) oder
/// eine einzelne Datei, jeweils mit optionalen Metadaten.
///
/// Liefert `true`, wenn der Upload gestartet wurde.
class UploadScreen extends StatefulWidget {
  const UploadScreen.scan({super.key, required List<Uint8List> this.pages})
    : fileName = null,
      fileBytes = null;

  const UploadScreen.file({
    super.key,
    required String this.fileName,
    required this.fileBytes,
  }) : pages = null;

  final List<Uint8List>? pages;
  final String? fileName;
  final Uint8List? fileBytes;

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  late final List<Uint8List>? _pages = widget.pages == null
      ? null
      : [...widget.pages!];
  final _title = TextEditingController();
  DateTime? _created;
  int? _correspondent;
  int? _documentType;
  int? _storagePath;
  Set<int> _tags = {};
  bool _busy = false;
  String? _error;

  bool get _isScan => _pages != null;

  @override
  void initState() {
    super.initState();
    if (!_isScan) {
      final name = widget.fileName!;
      final dot = name.lastIndexOf('.');
      _title.text = dot > 0 ? name.substring(0, dot) : name;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _addPages() async {
    try {
      final more = await ScanService.scanPages();
      if (more != null && mounted) setState(() => _pages!.addAll(more));
    } catch (e) {
      if (mounted) setState(() => _error = 'Scanner: $e');
    }
  }

  Future<void> _submit() async {
    if (_isScan && _pages!.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = AppScope.read(context);
    try {
      final title = _title.text.trim();
      final Uint8List bytes;
      final String fileName;
      if (_isScan) {
        bytes = await buildPdfFromImages(_pages!);
        fileName =
            'Scan ${DateFormat('yyyy-MM-dd HH-mm').format(DateTime.now())}.pdf';
      } else {
        bytes = widget.fileBytes!;
        fileName = widget.fileName!;
      }
      // Nicht abwarten: die Warteschlange zeigt den Fortschritt in der Liste.
      state.uploads.add(state.client, [
        UploadRequest(
          fileName,
          bytes,
          title: title.isEmpty ? null : title,
          created: _created,
          correspondent: _correspondent,
          documentType: _documentType,
          storagePath: _storagePath,
          tags: _tags.toList(),
        ),
      ]).ignore();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final client = state.client;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isScan ? 'Scan hochladen' : 'Datei hochladen'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _busy || (_isScan && _pages!.isEmpty) ? null : _submit,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(LucideIcons.upload),
              label: const Text('Hochladen'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 16,
                  children: [
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    if (_isScan) _pagesStrip(theme) else _fileInfo(theme),
                    TextField(
                      controller: _title,
                      decoration: const InputDecoration(
                        labelText: 'Titel',
                        hintText: 'Leer lassen: vom Server bestimmen',
                        prefixIcon: Icon(LucideIcons.type),
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _created ?? DateTime.now(),
                          firstDate: DateTime(1900),
                          lastDate: DateTime(DateTime.now().year + 1, 12, 31),
                        );
                        if (picked != null) setState(() => _created = picked);
                      },
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: 'Belegdatum',
                          prefixIcon: const Icon(LucideIcons.calendar),
                          suffixIcon: _created == null
                              ? null
                              : IconButton(
                                  tooltip: 'Automatisch erkennen',
                                  icon: const Icon(LucideIcons.x),
                                  onPressed: () =>
                                      setState(() => _created = null),
                                ),
                        ),
                        child: Text(
                          _created == null
                              ? 'Automatisch aus dem Text'
                              : formatDay(_created!),
                        ),
                      ),
                    ),
                    LabelField<Correspondent>(
                      label: 'Korrespondent',
                      icon: LucideIcons.user,
                      options: state.correspondents,
                      value: _correspondent,
                      onChanged: (v) => setState(() => _correspondent = v),
                      onCreate: client.user.can('add', 'correspondent')
                          ? state.createCorrespondent
                          : null,
                    ),
                    LabelField<DocumentType>(
                      label: 'Dokumenttyp',
                      icon: LucideIcons.fileType,
                      options: state.documentTypes,
                      value: _documentType,
                      onChanged: (v) => setState(() => _documentType = v),
                      onCreate: client.user.can('add', 'documenttype')
                          ? state.createDocumentType
                          : null,
                    ),
                    LabelField<StoragePath>(
                      label: 'Speicherpfad',
                      icon: LucideIcons.folderTree,
                      options: state.storagePaths,
                      value: _storagePath,
                      onChanged: (v) => setState(() => _storagePath = v),
                    ),
                    TagsField(
                      tags: state.tags,
                      selected: _tags,
                      onChanged: (v) {
                        setState(() => _tags = v);
                        state.refreshLabels().ignore();
                      },
                      onCreate: client.user.can('add', 'tag')
                          ? (name) => client.createTag(
                              name,
                              color: nextTagColor(state.tags.length),
                            )
                          : null,
                    ),
                    Text(
                      'Was du hier leer lässt, ergänzt der Server über seine Zuordnungsregeln.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileInfo(ThemeData theme) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(LucideIcons.fileText, size: 32),
    title: Text(widget.fileName!),
    subtitle: Text(
      '${(widget.fileBytes!.length / 1024).toStringAsFixed(0)} KB',
    ),
  );

  Widget _pagesStrip(ThemeData theme) {
    final pages = _pages!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                pages.length == 1 ? '1 Seite' : '${pages.length} Seiten',
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (ScanService.available)
              TextButton.icon(
                onPressed: _busy ? null : _addPages,
                icon: const Icon(LucideIcons.scanLine),
                label: const Text('Seiten hinzufügen'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 190,
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            itemCount: pages.length,
            onReorderItem: (from, to) =>
                setState(() => pages.insert(to, pages.removeAt(from))),
            itemBuilder: (context, i) => ReorderableDelayedDragStartListener(
              key: ObjectKey(pages[i]),
              index: i,
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(
                        pages[i],
                        height: 180,
                        width: 130,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: CircleAvatar(
                        radius: 12,
                        child: Text(
                          '${i + 1}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton.filledTonal(
                        tooltip: 'Seite entfernen',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(LucideIcons.trash2),
                        onPressed: () => setState(() => pages.removeAt(i)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Text(
          'Zum Umsortieren lange drücken und ziehen.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
