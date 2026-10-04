import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/label_pickers.dart';
import '../widgets/tag_chip.dart';

/// Metadaten eines Dokuments bearbeiten. Liefert das gespeicherte Dokument.
class DocumentEditScreen extends StatefulWidget {
  const DocumentEditScreen({super.key, required this.document});

  final Document document;

  @override
  State<DocumentEditScreen> createState() => _DocumentEditScreenState();
}

class _DocumentEditScreenState extends State<DocumentEditScreen> {
  late final _title = TextEditingController(text: widget.document.title);
  late final _asn = TextEditingController(
    text: widget.document.archiveSerialNumber?.toString() ?? '',
  );
  late DateTime _created = widget.document.created;
  late int? _correspondent = widget.document.correspondent;
  late int? _documentType = widget.document.documentType;
  late int? _storagePath = widget.document.storagePath;
  late Set<int> _tags = {...widget.document.tags};
  final _form = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
    _asn.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _asn.dispose();
    super.dispose();
  }

  int? get _asnValue => int.tryParse(_asn.text.trim());

  /// Nur geänderte Felder an den Server schicken.
  Map<String, Object?> get _changes {
    final d = widget.document;
    String day(DateTime x) => x.toIso8601String().substring(0, 10);
    return {
      if (_title.text.trim() != d.title) 'title': _title.text.trim(),
      if (day(_created) != day(d.created)) 'created_date': day(_created),
      if (_correspondent != d.correspondent) 'correspondent': _correspondent,
      if (_documentType != d.documentType) 'document_type': _documentType,
      if (_storagePath != d.storagePath) 'storage_path': _storagePath,
      if (_asnValue != d.archiveSerialNumber)
        'archive_serial_number': _asnValue,
      if (!(_tags.length == d.tags.length && _tags.containsAll(d.tags)))
        'tags': _tags.toList(),
    };
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final changes = _changes;
    if (changes.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final state = AppScope.read(context);
    try {
      final updated = await state.client.updateDocument(
        widget.document.id,
        changes,
      );
      state.refreshLabels().ignore();
      if (mounted) Navigator.pop(context, updated);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (_changes.isEmpty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Änderungen verwerfen?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Weiter bearbeiten'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Verwerfen'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _created,
      firstDate: DateTime(1900),
      lastDate: DateTime(DateTime.now().year + 1, 12, 31),
    );
    if (picked != null) setState(() => _created = picked);
  }

  Future<void> _nextAsn() async {
    try {
      final next = await AppScope.read(
        context,
      ).client.nextArchiveSerialNumber();
      _asn.text = '$next';
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final client = state.client;
    final theme = Theme.of(context);
    final changed = _changes.isNotEmpty;

    Widget labelField<T extends Label>({
      required String label,
      required IconData icon,
      required Map<int, T> options,
      required int? value,
      required ValueChanged<int?> onChanged,
      Future<T> Function(String)? onCreate,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () async {
            final picked = await pickLabel<T>(
              context,
              title: label,
              options: options.values.toList(),
              selected: value,
              onCreate: onCreate,
            );
            if (picked != null) onChanged(picked == -1 ? null : picked);
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: Icon(icon),
            ),
            child: Text(
              value == null ? '–' : (options[value]?.name ?? '#$value'),
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: !changed || _saving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Bearbeiten'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Speichern'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(
                              _error!,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        TextFormField(
                          controller: _title,
                          decoration: const InputDecoration(
                            labelText: 'Titel',
                            prefixIcon: Icon(LucideIcons.type),
                          ),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'Bitte einen Titel angeben'
                              : null,
                        ),
                        const SizedBox(height: 16),
                        InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: _pickDate,
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              labelText: 'Belegdatum',
                              prefixIcon: Icon(LucideIcons.calendar),
                            ),
                            child: Text(formatDay(_created)),
                          ),
                        ),
                        const SizedBox(height: 16),
                        labelField<Correspondent>(
                          label: 'Korrespondent',
                          icon: LucideIcons.user,
                          options: state.correspondents,
                          value: _correspondent,
                          onChanged: (v) => setState(() => _correspondent = v),
                          onCreate: client.user.can('add', 'correspondent')
                              ? client.createCorrespondent
                              : null,
                        ),
                        labelField<DocumentType>(
                          label: 'Dokumenttyp',
                          icon: LucideIcons.fileType,
                          options: state.documentTypes,
                          value: _documentType,
                          onChanged: (v) => setState(() => _documentType = v),
                          onCreate: client.user.can('add', 'documenttype')
                              ? client.createDocumentType
                              : null,
                        ),
                        labelField<StoragePath>(
                          label: 'Speicherpfad',
                          icon: LucideIcons.folderTree,
                          options: state.storagePaths,
                          value: _storagePath,
                          onChanged: (v) => setState(() => _storagePath = v),
                        ),
                        TextFormField(
                          controller: _asn,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'Archivnummer (ASN)',
                            prefixIcon: const Icon(LucideIcons.hash),
                            suffixIcon: IconButton(
                              tooltip: 'Nächste freie Nummer',
                              icon: const Icon(LucideIcons.listPlus),
                              onPressed: _nextAsn,
                            ),
                          ),
                          validator: (v) {
                            final s = (v ?? '').trim();
                            if (s.isEmpty) return null;
                            final n = int.tryParse(s);
                            return n == null || n < 0
                                ? 'Bitte eine ganze Zahl angeben'
                                : null;
                          },
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Tags',
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                            TextButton.icon(
                              icon: const Icon(LucideIcons.tags),
                              label: const Text('Auswählen'),
                              onPressed: () async {
                                final picked = await pickTags(
                                  context,
                                  options: state.tags.values.toList(),
                                  selected: _tags,
                                  onCreate: client.user.can('add', 'tag')
                                      ? (name) => client.createTag(
                                          name,
                                          color: nextTagColor(
                                            state.tags.length,
                                          ),
                                        )
                                      : null,
                                );
                                if (picked != null) {
                                  setState(() => _tags = picked);
                                  state.refreshLabels().ignore();
                                }
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_tags.isEmpty)
                          Text('Keine Tags', style: theme.textTheme.bodyMedium)
                        else
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final id in _tags)
                                if (state.tags[id] case final tag?)
                                  InputChip(
                                    label: TagChip(tag: tag),
                                    onDeleted: () => setState(
                                      () => _tags = {..._tags}..remove(id),
                                    ),
                                  ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
