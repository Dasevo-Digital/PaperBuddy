import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../../app_state.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/label_pickers.dart';
import '../../widgets/tag_chip.dart';
import '../../l10n.dart';

Map<int, String> get _triggerTypes => {
  1: tr.processingStarted,
  2: tr.documentAdded,
  3: tr.documentChanged,
  4: tr.scheduled,
};

Map<int, String> get _actionTypes => {
  1: tr.assign,
  2: tr.remove,
  3: tr.sendEmail,
  4: tr.callWebhook,
};

Map<int, String> get _sources => {1: tr.consumptionFolder, 2: tr.uploadSource, 3: tr.email};

class WorkflowsScreen extends StatefulWidget {
  const WorkflowsScreen({super.key});

  @override
  State<WorkflowsScreen> createState() => _WorkflowsScreenState();
}

class _WorkflowsScreenState extends State<WorkflowsScreen> {
  late Future<List<Workflow>> _items;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => _items = AppScope.read(context).client.workflows();

  Future<void> _edit([Workflow? w]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => WorkflowEditScreen(workflow: w)),
    );
    if (saved == true && mounted) setState(_reload);
  }

  Future<void> _toggle(Workflow w, bool enabled) async {
    w.enabled = enabled;
    await guarded(context, () => AppScope.read(context).client.saveWorkflow(w));
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    final user = AppScope.of(context).client.user;
    return Scaffold(
      appBar: AppBar(title: Text(tr.workflows)),
      floatingActionButton: user.can('add', 'workflow')
          ? FloatingActionButton(
              tooltip: tr.createWorkflow,
              onPressed: () => _edit(),
              child: const Icon(LucideIcons.plus),
            )
          : null,
      body: FutureBuilder<List<Workflow>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError) {
            return EmptyHint(icon: LucideIcons.cloudOff, text: '${snap.error}');
          }
          final items = snap.data;
          if (items == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (items.isEmpty) {
            return EmptyHint(
              icon: LucideIcons.workflow,
              text:
                  tr.workflowsIntro,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final w = items[i];
              return ListTile(
                leading: const Icon(LucideIcons.workflow),
                title: Text(w.name),
                subtitle: Text(
                  [
                    for (final t in w.triggers)
                      _triggerTypes[t['type']] ?? tr.trigger,
                    tr.actionsCount(w.actions.length),
                  ].join(' · '),
                ),
                onTap: user.can('change', 'workflow') ? () => _edit(w) : null,
                trailing: Switch(
                  value: w.enabled,
                  onChanged: user.can('change', 'workflow')
                      ? (v) => _toggle(w, v)
                      : null,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class WorkflowEditScreen extends StatefulWidget {
  const WorkflowEditScreen({super.key, this.workflow});
  final Workflow? workflow;

  @override
  State<WorkflowEditScreen> createState() => _WorkflowEditScreenState();
}

class _WorkflowEditScreenState extends State<WorkflowEditScreen> {
  late final Workflow _w = widget.workflow == null
      ? Workflow(
          name: '',
          triggers: [
            {
              'type': 1,
              'sources': [1, 2, 3],
              'filter_filename': '*',
            },
          ],
          actions: [
            {'type': 1},
          ],
        )
      : Workflow.fromJson({
          ...widget.workflow!.toJson(),
          'id': widget.workflow!.id,
        });
  late final _name = TextEditingController(text: _w.name);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _w.name = _name.text.trim();
    if (_w.name.isEmpty) {
      setState(() => _error = tr.pleaseEnterAName);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AppScope.read(context).client.saveWorkflow(_w);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: tr.deleteWorkflow,
      action: tr.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    final done = await guarded(
      context,
      () => AppScope.read(
        context,
      ).client.deleteWorkflow(_w.id!).then((_) => true),
    );
    if (done == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.workflow == null ? tr.createWorkflow : tr.editWorkflow,
        ),
        actions: [
          if (_w.id != null)
            IconButton(
              tooltip: tr.delete,
              icon: const Icon(LucideIcons.trash2),
              onPressed: _delete,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(tr.save),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  TextField(
                    controller: _name,
                    decoration: InputDecoration(labelText: tr.name),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: '${_w.order}',
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: tr.order,
                          ),
                          onChanged: (v) => _w.order = int.tryParse(v) ?? 0,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: SwitchListTile(
                          title: Text(tr.active),
                          value: _w.enabled,
                          onChanged: (v) => setState(() => _w.enabled = v),
                        ),
                      ),
                    ],
                  ),
                  _Section(
                    title: tr.trigger,
                    onAdd: () => setState(() => _w.triggers.add({'type': 2})),
                    children: [
                      for (final (i, t) in _w.triggers.indexed)
                        _TriggerCard(
                          key: ObjectKey(t),
                          trigger: t,
                          onChanged: () => setState(() {}),
                          onRemove: _w.triggers.length > 1
                              ? () => setState(() => _w.triggers.removeAt(i))
                              : null,
                        ),
                    ],
                  ),
                  _Section(
                    title: tr.actions,
                    onAdd: () => setState(() => _w.actions.add({'type': 1})),
                    children: [
                      for (final (i, a) in _w.actions.indexed)
                        _ActionCard(
                          key: ObjectKey(a),
                          action: a,
                          onChanged: () => setState(() {}),
                          onRemove: _w.actions.length > 1
                              ? () => setState(() => _w.actions.removeAt(i))
                              : null,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.onAdd,
    required this.children,
  });
  final String title;
  final VoidCallback onAdd;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(LucideIcons.plus),
            label: Text(tr.add),
          ),
        ],
      ),
      ...children,
    ],
  );
}

List<int> _ids(Object? v) => v is List
    ? [
        for (final e in v)
          if (e is int) e,
      ]
    : [];

/// Feld für eine Mehrfachauswahl von Tags in einer Map.
Widget _tagsField(
  BuildContext context,
  Map<String, dynamic> map,
  String key,
  String label,
  VoidCallback onChanged,
) {
  final state = AppScope.of(context);
  final selected = _ids(map[key]).toSet();
  return InkWell(
    onTap: () async {
      final picked = await pickTags(
        context,
        options: state.tags.values.toList(),
        selected: selected,
      );
      if (picked != null) {
        map[key] = picked.toList();
        onChanged();
      }
    },
    child: InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: selected.isEmpty
          ? const Text('–')
          : Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final id in selected)
                  if (state.tags[id] case final t?) TagChip(tag: t),
              ],
            ),
    ),
  );
}

Widget _labelField<T extends Label>(
  BuildContext context,
  Map<String, dynamic> map,
  String key,
  String label,
  Map<int, T> options,
  VoidCallback onChanged,
) {
  return LabelField<T>(
    label: label,
    icon: LucideIcons.tag,
    options: options,
    value: map[key] as int?,
    onChanged: (v) {
      map[key] = v;
      onChanged();
    },
  );
}

Widget _text(
  Map<String, dynamic> map,
  String key,
  String label,
  VoidCallback onChanged, {
  String? hint,
  int maxLines = 1,
  Map<String, dynamic>? target,
}) => TextFormField(
  initialValue: ((target ?? map)[key] ?? '').toString(),
  maxLines: maxLines,
  decoration: InputDecoration(labelText: label, hintText: hint),
  onChanged: (v) {
    (target ?? map)[key] = v.isEmpty ? null : v;
    onChanged();
  },
);

class _TriggerCard extends StatelessWidget {
  const _TriggerCard({
    super.key,
    required this.trigger,
    required this.onChanged,
    this.onRemove,
  });
  final Map<String, dynamic> trigger;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final type = trigger['type'] as int? ?? 1;
    final sources = _ids(trigger['sources'] ?? [1, 2, 3]).toSet();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: type,
                    decoration: InputDecoration(labelText: tr.when),
                    items: [
                      for (final e in _triggerTypes.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) {
                      trigger['type'] = v;
                      onChanged();
                    },
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: tr.remove,
                    icon: const Icon(LucideIcons.x),
                    onPressed: onRemove,
                  ),
              ],
            ),
            if (type == 1 || type == 2)
              Wrap(
                spacing: 6,
                children: [
                  for (final e in _sources.entries)
                    FilterChip(
                      label: Text(e.value),
                      selected: sources.contains(e.key),
                      onSelected: (v) {
                        trigger['sources'] =
                            (v
                                    ? ({...sources, e.key})
                                    : ({...sources}..remove(e.key)))
                                .toList();
                        onChanged();
                      },
                    ),
                ],
              ),
            _text(
              trigger,
              'filter_filename',
              tr.fileNameMatches,
              onChanged,
              hint: tr.pdfOrInvoice,
            ),
            if (type == 1)
              _text(
                trigger,
                'filter_path',
                tr.pathMatches,
                onChanged,
                hint: '*/Rechnungen/*',
              ),
            if (type != 1) ...[
              _tagsField(
                context,
                trigger,
                'filter_has_tags',
                tr.hasAllTheseTags,
                onChanged,
              ),
              _labelField<Correspondent>(
                context,
                trigger,
                'filter_has_correspondent',
                tr.hasCorrespondent,
                state.correspondents,
                onChanged,
              ),
              _labelField<DocumentType>(
                context,
                trigger,
                'filter_has_document_type',
                tr.hasDocumentType,
                state.documentTypes,
                onChanged,
              ),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: trigger['matching_algorithm'] as int? ?? 0,
                      decoration: InputDecoration(labelText: tr.content),
                      items: [
                        for (final m in MatchingAlgorithm.values.where(
                          (m) => m != MatchingAlgorithm.auto,
                        ))
                          DropdownMenuItem(
                            value: m.value,
                            child: Text(
                              m == MatchingAlgorithm.none
                                  ? tr.any
                                  : m.label,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        trigger['matching_algorithm'] = v;
                        onChanged();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _text(trigger, 'match', tr.searchTerm, onChanged),
                  ),
                ],
              ),
            ],
            if (type == 4) ...[
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue:
                          trigger['schedule_date_field'] as String? ?? 'added',
                      decoration: InputDecoration(
                        labelText: tr.basedOn,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'added',
                          child: Text(tr.added),
                        ),
                        DropdownMenuItem(
                          value: 'created',
                          child: Text(tr.documentDate),
                        ),
                        DropdownMenuItem(
                          value: 'modified',
                          child: Text(tr.modified),
                        ),
                      ],
                      onChanged: (v) {
                        trigger['schedule_date_field'] = v;
                        onChanged();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      initialValue: '${trigger['schedule_offset_days'] ?? 0}',
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: tr.afterDays,
                      ),
                      onChanged: (v) => trigger['schedule_offset_days'] =
                          int.tryParse(v) ?? 0,
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr.repeat),
                value: trigger['schedule_is_recurring'] == true,
                onChanged: (v) {
                  trigger['schedule_is_recurring'] = v;
                  onChanged();
                },
              ),
              if (trigger['schedule_is_recurring'] == true)
                TextFormField(
                  initialValue:
                      '${trigger['schedule_recurring_interval_days'] ?? 1}',
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: tr.everyDays),
                  onChanged: (v) =>
                      trigger['schedule_recurring_interval_days'] =
                          int.tryParse(v) ?? 1,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.action,
    required this.onChanged,
    this.onRemove,
  });
  final Map<String, dynamic> action;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final type = action['type'] as int? ?? 1;
    final email =
        (action['email'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    final webhook =
        (action['webhook'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: type,
                    decoration: InputDecoration(labelText: tr.action),
                    items: [
                      for (final e in _actionTypes.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) {
                      action['type'] = v;
                      if (v == 3) {
                        action['email'] ??= <String, dynamic>{
                          'subject': '{doc_title}',
                          'body': '',
                          'to': '',
                        };
                      }
                      if (v == 4) {
                        action['webhook'] ??= <String, dynamic>{
                          'url': '',
                          'body': '',
                        };
                      }
                      onChanged();
                    },
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: tr.remove,
                    icon: const Icon(LucideIcons.x),
                    onPressed: onRemove,
                  ),
              ],
            ),
            if (type == 1) ...[
              _text(
                action,
                'assign_title',
                tr.title,
                onChanged,
                hint: '{correspondent} {created_year}-{created_month}',
              ),
              _tagsField(
                context,
                action,
                'assign_tags',
                tr.addTags,
                onChanged,
              ),
              _labelField<Correspondent>(
                context,
                action,
                'assign_correspondent',
                tr.correspondent,
                state.correspondents,
                onChanged,
              ),
              _labelField<DocumentType>(
                context,
                action,
                'assign_document_type',
                tr.documentType,
                state.documentTypes,
                onChanged,
              ),
              _labelField<StoragePath>(
                context,
                action,
                'assign_storage_path',
                tr.storagePath,
                state.storagePaths,
                onChanged,
              ),
              if (state.users.isNotEmpty)
                DropdownButtonFormField<int?>(
                  initialValue: action['assign_owner'] as int?,
                  decoration: InputDecoration(labelText: tr.owner),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('–')),
                    for (final u in state.users.values)
                      DropdownMenuItem(value: u.id, child: Text(u.displayName)),
                  ],
                  onChanged: (v) {
                    action['assign_owner'] = v;
                    onChanged();
                  },
                ),
              Text(
                'Platzhalter: {correspondent}, {document_type}, {created}, {created_year}, {added}, {original_filename} …',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (type == 2) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr.removeAllTags),
                value: action['remove_all_tags'] == true,
                onChanged: (v) {
                  action['remove_all_tags'] = v;
                  onChanged();
                },
              ),
              if (action['remove_all_tags'] != true)
                _tagsField(
                  context,
                  action,
                  'remove_tags',
                  tr.removeTheseTags,
                  onChanged,
                ),
              for (final (key, label) in [
                ('remove_all_correspondents', tr.removeCorrespondent),
                ('remove_all_document_types', tr.removeDocumentType),
                ('remove_all_storage_paths', tr.removeStoragePath),
                ('remove_all_custom_fields', tr.removeAllCustomFields),
                ('remove_all_permissions', tr.removeAllPermissions),
              ])
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(label),
                  value: action[key] == true,
                  onChanged: (v) {
                    action[key] = v;
                    onChanged();
                  },
                ),
            ],
            if (type == 3) ...[
              _text(email, 'to', tr.toCommaSeparated, () {
                action['email'] = email;
                onChanged();
              }),
              _text(email, 'subject', tr.subject, () {
                action['email'] = email;
                onChanged();
              }),
              _text(email, 'body', tr.text, () {
                action['email'] = email;
                onChanged();
              }, maxLines: 4),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr.attachDocument),
                value: email['include_document'] == true,
                onChanged: (v) {
                  email['include_document'] = v;
                  action['email'] = email;
                  onChanged();
                },
              ),
            ],
            if (type == 4) ...[
              _text(webhook, 'url', 'URL', () {
                action['webhook'] = webhook;
                onChanged();
              }, hint: 'https://example.org/hook'),
              _text(
                webhook,
                'body',
                tr.content,
                () {
                  action['webhook'] = webhook;
                  onChanged();
                },
                maxLines: 4,
                hint: '{"titel": "{doc_title}", "link": "{doc_url}"}',
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr.sendDocumentAlong),
                value: webhook['include_document'] == true,
                onChanged: (v) {
                  webhook['include_document'] = v;
                  action['webhook'] = webhook;
                  onChanged();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
