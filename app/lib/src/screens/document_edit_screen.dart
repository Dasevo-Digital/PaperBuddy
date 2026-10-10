import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/custom_field_inputs.dart';
import '../widgets/label_pickers.dart';

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
  late List<CustomFieldValue> _fields = [...widget.document.customFields];
  final _form = GlobalKey<FormState>();
  DocumentSuggestions? _suggestions;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
    _asn.addListener(() => setState(() {}));
    AppScope.read(context).client.suggestions(widget.document.id).then(
      (s) {
        if (mounted) setState(() => _suggestions = s);
      },
      // Ältere Server ohne Vorschläge: dann eben keine.
      onError: (Object _) {},
    );
  }

  @override
  void dispose() {
    _title.dispose();
    _asn.dispose();
    super.dispose();
  }

  static bool _sameFields(List<CustomFieldValue> a, List<CustomFieldValue> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].field != b[i].field || '${a[i].value}' != '${b[i].value}') {
        return false;
      }
    }
    return true;
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
      if (!_sameFields(_fields, d.customFields))
        'custom_fields': [for (final f in _fields) f.toJson()],
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

  /// Vorschläge des Servers, die noch nicht übernommen sind; ein Tipp
  /// übernimmt den Wert. `null`, wenn es keine (mehr) gibt.
  Widget? _suggestionChips(AppState state) {
    final s = _suggestions;
    if (s == null) return null;
    final chips = <Widget>[
      for (final d in s.dates)
        if (!DateUtils.isSameDay(d, _created))
          ActionChip(
            avatar: const Icon(LucideIcons.calendar, size: 16),
            label: Text(formatDay(d)),
            onPressed: () => setState(() => _created = d),
          ),
      for (final id in s.correspondents)
        if (id != _correspondent && state.correspondents[id] != null)
          ActionChip(
            avatar: const Icon(LucideIcons.user, size: 16),
            label: Text(state.correspondents[id]!.name),
            onPressed: () => setState(() => _correspondent = id),
          ),
      for (final id in s.documentTypes)
        if (id != _documentType && state.documentTypes[id] != null)
          ActionChip(
            avatar: const Icon(LucideIcons.fileType, size: 16),
            label: Text(state.documentTypes[id]!.name),
            onPressed: () => setState(() => _documentType = id),
          ),
      for (final id in s.storagePaths)
        if (id != _storagePath && state.storagePaths[id] != null)
          ActionChip(
            avatar: const Icon(LucideIcons.folderTree, size: 16),
            label: Text(state.storagePaths[id]!.name),
            onPressed: () => setState(() => _storagePath = id),
          ),
      for (final id in s.tags)
        if (!_tags.contains(id) && state.tags[id] != null)
          ActionChip(
            avatar: const Icon(LucideIcons.tag, size: 16),
            label: Text(state.tags[id]!.name),
            onPressed: () => setState(() => _tags = {..._tags, id}),
          ),
    ];
    if (chips.isEmpty) return null;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Row(
          spacing: 6,
          children: [
            Icon(
              LucideIcons.sparkles,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            Text('Vorschläge', style: theme.textTheme.labelLarge),
          ],
        ),
        Wrap(spacing: 6, runSpacing: 6, children: chips),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final client = state.client;
    final theme = Theme.of(context);
    final changed = _changes.isNotEmpty;

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
                      spacing: 16,
                      children: [
                        if (_error != null)
                          Text(
                            _error!,
                            style: TextStyle(color: theme.colorScheme.error),
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
                        ?_suggestionChips(state),
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
                        if (state.customFields.isNotEmpty || _fields.isNotEmpty)
                          CustomFieldsEditor(
                            values: _fields,
                            onChanged: (v) => setState(() => _fields = v),
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
