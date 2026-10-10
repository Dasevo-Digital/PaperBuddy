import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../format.dart';
import '../l10n.dart';

/// Wert eines Custom Fields lesbar machen.
String formatCustomValue(CustomField? field, Object? value) {
  if (value == null || (value is String && value.isEmpty)) return '–';
  switch (field?.type) {
    case CustomFieldType.boolean:
      return value == true ? tr.yes : tr.no;
    case CustomFieldType.date:
      final d = DateTime.tryParse('$value');
      return d == null ? '$value' : formatDay(d);
    case CustomFieldType.monetary:
      final m = RegExp(r'^([A-Z]{3})?(-?[\d.]+)$').firstMatch('$value');
      if (m == null) return '$value';
      final amount =
          double.tryParse(
            m.group(2)!,
          )?.toStringAsFixed(2).replaceAll('.', ',') ??
          m.group(2)!;
      return '$amount ${m.group(1) ?? field?.defaultCurrency ?? ''}'.trim();
    case CustomFieldType.select:
      return field!.options.where((o) => o.id == '$value').firstOrNull?.label ??
          '$value';
    case CustomFieldType.documentlink:
      return value is List ? value.map((e) => '#$e').join(', ') : '$value';
    default:
      return '$value';
  }
}

/// Bearbeitet die Custom-Field-Werte eines Dokuments.
class CustomFieldsEditor extends StatelessWidget {
  const CustomFieldsEditor({
    super.key,
    required this.values,
    required this.onChanged,
  });

  final List<CustomFieldValue> values;
  final ValueChanged<List<CustomFieldValue>> onChanged;

  void _set(int field, Object? value) => onChanged([
    for (final v in values)
      v.field == field ? CustomFieldValue(field, value) : v,
  ]);

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final used = values.map((v) => v.field).toSet();
    final available =
        state.customFields.values.where((f) => !used.contains(f.id)).toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Custom Fields', style: theme.textTheme.titleMedium),
            ),
            if (available.isNotEmpty)
              PopupMenuButton<CustomField>(
                tooltip: tr.addField,
                onSelected: (f) =>
                    onChanged([...values, CustomFieldValue(f.id, null)]),
                itemBuilder: (_) => [
                  for (final f in available)
                    PopupMenuItem(value: f, child: Text(f.name)),
                ],
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.plus, size: 18),
                      SizedBox(width: 6),
                      Text(tr.addField),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (values.isEmpty)
          Text(tr.noFields, style: theme.textTheme.bodyMedium),
        for (final v in values)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _FieldInput(
                  key: ValueKey(v.field),
                  field: state.customFields[v.field],
                  value: v.value,
                  onChanged: (x) => _set(v.field, x),
                ),
              ),
              IconButton(
                tooltip: tr.removeField,
                icon: const Icon(LucideIcons.x),
                onPressed: () => onChanged([
                  for (final x in values)
                    if (x.field != v.field) x,
                ]),
              ),
            ],
          ),
      ],
    );
  }
}

class _FieldInput extends StatefulWidget {
  const _FieldInput({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
  });
  final CustomField? field;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  @override
  State<_FieldInput> createState() => _FieldInputState();
}

class _FieldInputState extends State<_FieldInput> {
  late final _text = TextEditingController(text: _initialText());

  String _initialText() {
    final v = widget.value;
    if (v == null) return '';
    if (widget.field?.type == CustomFieldType.monetary) {
      return '$v'.replaceAll(RegExp('^[A-Z]{3}'), '').replaceAll('.', ',');
    }
    if (widget.field?.type == CustomFieldType.documentlink && v is List) {
      return v.join(', ');
    }
    return '$v';
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    final label = f?.name ?? tr.field;
    switch (f?.type) {
      case CustomFieldType.boolean:
        return CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          value: widget.value == true,
          onChanged: (v) => widget.onChanged(v ?? false),
        );
      case CustomFieldType.date:
        final d = widget.value == null
            ? null
            : DateTime.tryParse('${widget.value}');
        return InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: d ?? DateTime.now(),
              firstDate: DateTime(1900),
              lastDate: DateTime(2100),
            );
            if (picked != null) {
              widget.onChanged(picked.toIso8601String().substring(0, 10));
            }
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: const Icon(LucideIcons.calendar),
            ),
            child: Text(d == null ? '–' : formatDay(d)),
          ),
        );
      case CustomFieldType.select:
        return DropdownButtonFormField<String?>(
          initialValue: f!.options.any((o) => o.id == '${widget.value}')
              ? '${widget.value}'
              : null,
          decoration: InputDecoration(labelText: label),
          items: [
            const DropdownMenuItem(value: null, child: Text('–')),
            for (final o in f.options)
              DropdownMenuItem(value: o.id, child: Text(o.label)),
          ],
          onChanged: widget.onChanged,
        );
      case CustomFieldType.integer || CustomFieldType.float:
        return TextField(
          controller: _text,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(labelText: label),
          onChanged: (v) {
            final s = v.trim().replaceAll(',', '.');
            widget.onChanged(
              s.isEmpty
                  ? null
                  : f!.type == CustomFieldType.integer
                  ? int.tryParse(s)
                  : double.tryParse(s),
            );
          },
        );
      case CustomFieldType.monetary:
        final currency =
            RegExp(
              '^([A-Z]{3})',
            ).firstMatch('${widget.value ?? ''}')?.group(1) ??
            f!.defaultCurrency ??
            'EUR';
        return TextField(
          controller: _text,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, suffixText: currency),
          onChanged: (v) {
            final amount = double.tryParse(
              v.trim().replaceAll('.', '').replaceAll(',', '.'),
            );
            widget.onChanged(
              amount == null ? null : '$currency${amount.toStringAsFixed(2)}',
            );
          },
        );
      case CustomFieldType.documentlink:
        return TextField(
          controller: _text,
          decoration: InputDecoration(
            labelText: label,
            hintText: tr.documentIdsHint,
          ),
          onChanged: (v) => widget.onChanged([
            for (final p in v.split(RegExp(r'[,\s]+')))
              ?int.tryParse(p.replaceAll('#', '')),
          ]),
        );
      default:
        return TextField(
          controller: _text,
          maxLines: f?.type == CustomFieldType.longtext ? 4 : 1,
          keyboardType: f?.type == CustomFieldType.url
              ? TextInputType.url
              : null,
          decoration: InputDecoration(labelText: label),
          onChanged: (v) => widget.onChanged(v.isEmpty ? null : v),
        );
    }
  }
}
