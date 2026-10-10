import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../../app_state.dart';
import '../../format.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/label_pickers.dart';
import '../../widgets/tag_chip.dart';
import '../../l10n.dart';

/// Tags, Korrespondenten, Dokumenttypen oder Speicherpfade verwalten.
class LabelsScreen extends StatefulWidget {
  const LabelsScreen({super.key, required this.kind});
  final LabelKind kind;

  @override
  State<LabelsScreen> createState() => _LabelsScreenState();
}

class _LabelsScreenState extends State<LabelsScreen> {
  late Future<List<Label>> _items;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _items = AppScope.read(context).client.labels(widget.kind);
  }

  Future<void> _edit([Label? label]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => LabelEditDialog(kind: widget.kind, label: label),
    );
    if (saved == true && mounted) {
      setState(_reload);
      AppScope.read(context).refreshLabels().ignore();
    }
  }

  Future<void> _delete(Label label) async {
    final ok = await confirm(
      context,
      title: tr.deleteKindQuestion(widget.kind.singular),
      message:
          tr.willBeRemovedAffectedDocuments(label.name, label.documentCount),
      action: tr.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    final state = AppScope.read(context);
    await guarded(
      context,
      () => state.client.deleteLabel(widget.kind, label.id),
    );
    if (mounted) setState(_reload);
    state.refreshLabels().ignore();
  }

  @override
  Widget build(BuildContext context) {
    final user = AppScope.of(context).client.user;
    return Scaffold(
      appBar: AppBar(title: Text(widget.kind.plural)),
      floatingActionButton: user.can('add', widget.kind.model)
          ? FloatingActionButton(
              tooltip: tr.createKind(widget.kind.singular),
              onPressed: () => _edit(),
              child: const Icon(LucideIcons.plus),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: tr.search,
                prefixIcon: Icon(LucideIcons.search),
              ),
              onChanged: (v) =>
                  setState(() => _filter = v.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Label>>(
              future: _items,
              builder: (context, snap) {
                if (snap.hasError) {
                  return EmptyHint(
                    icon: LucideIcons.cloudOff,
                    text: '${snap.error}',
                  );
                }
                final items = snap.data;
                if (items == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final shown =
                    items
                        .where((l) => l.name.toLowerCase().contains(_filter))
                        .toList()
                      ..sort(
                        (a, b) => a.name.toLowerCase().compareTo(
                          b.name.toLowerCase(),
                        ),
                      );
                if (shown.isEmpty) {
                  return EmptyHint(
                    icon: LucideIcons.tags,
                    text: tr.noKind(widget.kind.plural),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async => setState(_reload),
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: shown.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final l = shown[i];
                      final algorithm = MatchingAlgorithm.of(
                        l.matchingAlgorithm,
                      );
                      return ListTile(
                        leading: l is Tag
                            ? CircleAvatar(
                                backgroundColor: Color(parseHexColor(l.color)),
                                radius: 10,
                              )
                            : null,
                        title: l is Tag
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: TagChip(tag: l, dense: false),
                              )
                            : Text(l.name),
                        subtitle: Text(
                          [
                            tr.documentsCount(l.documentCount),
                            if (algorithm != MatchingAlgorithm.none)
                              algorithm == MatchingAlgorithm.auto
                                  ? algorithm.label
                                  : '${algorithm.label}: ${l.match}',
                            if (l is Tag && l.isInboxTag) tr.inbox,
                            if (l is StoragePath && l.path.isNotEmpty) l.path,
                          ].join(' · '),
                        ),
                        onTap:
                            l.userCanChange &&
                                user.can('change', widget.kind.model)
                            ? () => _edit(l)
                            : null,
                        trailing:
                            l.userCanChange &&
                                user.can('delete', widget.kind.model)
                            ? IconButton(
                                tooltip: tr.delete,
                                icon: const Icon(LucideIcons.trash2),
                                onPressed: () => _delete(l),
                              )
                            : null,
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Anlegen oder Bearbeiten eines Labels samt Zuordnungsregel.
class LabelEditDialog extends StatefulWidget {
  const LabelEditDialog({super.key, required this.kind, this.label});
  final LabelKind kind;
  final Label? label;

  @override
  State<LabelEditDialog> createState() => _LabelEditDialogState();
}

class _LabelEditDialogState extends State<LabelEditDialog> {
  late final _name = TextEditingController(text: widget.label?.name ?? '');
  late final _match = TextEditingController(text: widget.label?.match ?? '');
  late final _path = TextEditingController(
    text: switch (widget.label) {
      StoragePath p => p.path,
      _ => '',
    },
  );
  late MatchingAlgorithm _algorithm = widget.label == null
      ? MatchingAlgorithm.auto
      : MatchingAlgorithm.of(widget.label!.matchingAlgorithm);
  late bool _insensitive = widget.label?.isInsensitive ?? true;
  late String _color = switch (widget.label) {
    Tag t => t.color,
    _ => nextTagColor(DateTime.now().millisecond),
  };
  late bool _inbox = switch (widget.label) {
    Tag t => t.isInboxTag,
    _ => false,
  };
  bool _saving = false;
  String? _error;

  static const _palette = [
    '#a6cee3',
    '#1f78b4',
    '#b2df8a',
    '#33a02c',
    '#fb9a99',
    '#e31a1c',
    '#fdbf6f',
    '#ff7f00',
    '#cab2d6',
    '#6a3d9a',
    '#b15928',
    '#000000',
  ];

  @override
  void dispose() {
    _name.dispose();
    _match.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = tr.pleaseEnterAName);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final data = <String, Object?>{
      'name': _name.text.trim(),
      'matching_algorithm': _algorithm.value,
      'match': _match.text.trim(),
      'is_insensitive': _insensitive,
      if (widget.kind == LabelKind.tag) ...{
        'color': _color,
        'is_inbox_tag': _inbox,
      },
      if (widget.kind == LabelKind.storagePath) 'path': _path.text.trim(),
    };
    final client = AppScope.read(context).client;
    try {
      if (widget.label == null) {
        await client.createLabel(widget.kind, data);
      } else {
        await client.updateLabel(widget.kind, widget.label!.id, data);
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final needsMatch =
        _algorithm != MatchingAlgorithm.none &&
        _algorithm != MatchingAlgorithm.auto;
    return AlertDialog(
      title: Text(
        widget.label == null
            ? tr.createKind(widget.kind.singular)
            : tr.editKind(widget.kind.singular),
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr.name,
                  errorText: _error,
                ),
              ),
              if (widget.kind == LabelKind.tag) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in _palette)
                      InkWell(
                        onTap: () => setState(() => _color = c),
                        customBorder: const CircleBorder(),
                        child: CircleAvatar(
                          radius: 14,
                          backgroundColor: Color(parseHexColor(c)),
                          child: _color == c
                              ? const Icon(
                                  LucideIcons.check,
                                  size: 16,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr.inboxTag),
                  subtitle: Text(tr.assignedToEveryNewDocument),
                  value: _inbox,
                  onChanged: (v) => setState(() => _inbox = v),
                ),
              ],
              if (widget.kind == LabelKind.storagePath)
                TextField(
                  controller: _path,
                  decoration: InputDecoration(
                    labelText: tr.path,
                    hintText: '{created_year}/{correspondent}/{title}',
                  ),
                ),
              DropdownButtonFormField<MatchingAlgorithm>(
                initialValue: _algorithm,
                decoration: InputDecoration(
                  labelText: tr.assignAutomatically,
                ),
                items: [
                  for (final m in MatchingAlgorithm.values)
                    DropdownMenuItem(value: m, child: Text(m.label)),
                ],
                onChanged: (v) =>
                    setState(() => _algorithm = v ?? MatchingAlgorithm.none),
              ),
              if (_algorithm == MatchingAlgorithm.auto)
                Text(
                  tr.learnsFromTheDocumentsYou,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (needsMatch) ...[
                TextField(
                  controller: _match,
                  decoration: InputDecoration(
                    labelText: tr.searchTerm,
                    hintText: _algorithm == MatchingAlgorithm.regex
                        ? r'Rechnung\s+Nr'
                        : tr.utilityCompany,
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr.ignoreCase),
                  value: _insensitive,
                  onChanged: (v) => setState(() => _insensitive = v ?? true),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(tr.save),
        ),
      ],
    );
  }
}
