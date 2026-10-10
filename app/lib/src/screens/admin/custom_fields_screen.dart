import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../../app_state.dart';
import '../../widgets/dialogs.dart';
import '../../l10n.dart';

/// Custom Fields anlegen, umbenennen, Auswahloptionen pflegen, löschen.
class CustomFieldsScreen extends StatelessWidget {
  const CustomFieldsScreen({super.key});

  Future<void> _edit(BuildContext context, [CustomField? field]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _FieldDialog(field: field),
    );
    if (saved == true && context.mounted) {
      await AppScope.read(context).refreshLabels();
    }
  }

  Future<void> _delete(BuildContext context, CustomField f) async {
    final ok = await confirm(
      context,
      title: tr.deleteField,
      message:
          tr.andItsValuesOnDocument(f.name, f.documentCount),
      action: tr.delete,
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final state = AppScope.read(context);
    await guarded(context, () => state.client.deleteCustomField(f.id));
    await state.refreshLabels();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final user = state.client.user;
    final fields = state.customFields.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Scaffold(
      appBar: AppBar(title: const Text('Custom Fields')),
      floatingActionButton: user.can('add', 'customfield')
          ? FloatingActionButton(
              tooltip: tr.createField,
              onPressed: () => _edit(context),
              child: const Icon(LucideIcons.plus),
            )
          : null,
      body: fields.isEmpty
          ? EmptyHint(
              icon: LucideIcons.textCursorInput,
              text:
                  tr.noCustomFieldsYetThey,
            )
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: fields.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final f = fields[i];
                return ListTile(
                  leading: Icon(_icon(f.type)),
                  title: Text(f.name),
                  subtitle: Text(
                    [
                      f.type.label,
                      if (f.type == CustomFieldType.select)
                        f.options.map((o) => o.label).join(', '),
                      tr.documentsCount(f.documentCount),
                    ].join(' · '),
                  ),
                  onTap: user.can('change', 'customfield')
                      ? () => _edit(context, f)
                      : null,
                  trailing: user.can('delete', 'customfield')
                      ? IconButton(
                          tooltip: tr.delete,
                          icon: const Icon(LucideIcons.trash2),
                          onPressed: () => _delete(context, f),
                        )
                      : null,
                );
              },
            ),
    );
  }

  static IconData _icon(CustomFieldType t) => switch (t) {
    CustomFieldType.string || CustomFieldType.longtext => LucideIcons.type,
    CustomFieldType.url => LucideIcons.link,
    CustomFieldType.date => LucideIcons.calendar,
    CustomFieldType.boolean => LucideIcons.squareCheck,
    CustomFieldType.integer || CustomFieldType.float => LucideIcons.hash,
    CustomFieldType.monetary => LucideIcons.euro,
    CustomFieldType.documentlink => LucideIcons.fileSymlink,
    CustomFieldType.select => LucideIcons.listChecks,
  };
}

class _FieldDialog extends StatefulWidget {
  const _FieldDialog({this.field});
  final CustomField? field;

  @override
  State<_FieldDialog> createState() => _FieldDialogState();
}

class _FieldDialogState extends State<_FieldDialog> {
  late final _name = TextEditingController(text: widget.field?.name ?? '');
  late CustomFieldType _type = widget.field?.type ?? CustomFieldType.string;
  late final List<SelectOption> _options = [...?widget.field?.options];
  final _option = TextEditingController();
  final _currency = TextEditingController(text: 'EUR');
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _option.dispose();
    _currency.dispose();
    super.dispose();
  }

  void _addOption() {
    final label = _option.text.trim();
    if (label.isEmpty) return;
    setState(() {
      _options.add(SelectOption('', label));
      _option.clear();
    });
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = tr.pleaseEnterAName);
      return;
    }
    setState(() => _saving = true);
    final client = AppScope.read(context).client;
    try {
      if (widget.field == null) {
        await client.createCustomField(
          _name.text.trim(),
          _type,
          options: [for (final o in _options) o.label],
          defaultCurrency: _currency.text.trim().toUpperCase(),
        );
      } else {
        await client.updateCustomField(
          widget.field!.id,
          name: _name.text.trim(),
          options: _type == CustomFieldType.select ? _options : null,
        );
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
    return AlertDialog(
      title: Text(widget.field == null ? tr.createField : tr.editField),
      content: SizedBox(
        width: 400,
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
              DropdownButtonFormField<CustomFieldType>(
                initialValue: _type,
                decoration: InputDecoration(
                  labelText: tr.dataType,
                  helperText: widget.field != null
                      ? tr.cannotBeChangedLater
                      : null,
                ),
                items: [
                  for (final t in CustomFieldType.values)
                    DropdownMenuItem(value: t, child: Text(t.label)),
                ],
                onChanged: widget.field != null
                    ? null
                    : (v) => setState(() => _type = v ?? _type),
              ),
              if (_type == CustomFieldType.monetary && widget.field == null)
                TextField(
                  controller: _currency,
                  decoration: InputDecoration(
                    labelText: tr.defaultCurrency,
                  ),
                ),
              if (_type == CustomFieldType.select) ...[
                for (final (i, o) in _options.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(o.label),
                    trailing: IconButton(
                      tooltip: tr.removeOption,
                      icon: const Icon(LucideIcons.x),
                      onPressed: () => setState(() => _options.removeAt(i)),
                    ),
                  ),
                TextField(
                  controller: _option,
                  decoration: InputDecoration(
                    labelText: tr.addOption,
                    suffixIcon: IconButton(
                      icon: const Icon(LucideIcons.plus),
                      onPressed: _addOption,
                    ),
                  ),
                  onSubmitted: (_) => _addOption(),
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
