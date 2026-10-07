import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../format.dart';
import 'dialogs.dart';

/// Fristen eines Dokuments in der Detailansicht: abhaken, löschen, neue
/// anlegen (z. B. „Kündigungsfrist“ an einem Vertrag).
class RemindersSection extends StatefulWidget {
  const RemindersSection({super.key, required this.documentId});

  final int documentId;

  @override
  State<RemindersSection> createState() => _RemindersSectionState();
}

class _RemindersSectionState extends State<RemindersSection> {
  List<Reminder>? _reminders;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await AppScope.read(
        context,
      ).client.reminders(document: widget.documentId);
      if (mounted) setState(() => _reminders = list);
    } on ApiException {
      if (mounted) setState(() => _reminders = []);
    }
  }

  Future<void> _add() async {
    final result = await showReminderDialog(context);
    if (result == null || !mounted) return;
    final client = AppScope.read(context).client;
    await guarded(
      context,
      () => client.createReminder(
        widget.documentId,
        result.due,
        note: result.note,
      ),
    );
    await _changed();
  }

  /// Nach Änderungen: Liste und Benachrichtigungen sofort abgleichen.
  Future<void> _changed() async {
    if (!mounted) return;
    final state = AppScope.read(context);
    state.notifications.refresh().ignore();
    state.remindersChanged.value++;
    await _load();
  }

  Future<void> _setDone(Reminder r, bool done) async {
    final client = AppScope.read(context).client;
    await guarded(context, () => client.updateReminder(r.id, done: done));
    await _changed();
  }

  Future<void> _delete(Reminder r) async {
    final client = AppScope.read(context).client;
    await guarded(context, () => client.deleteReminder(r.id));
    await _changed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reminders = _reminders;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Fristen', style: theme.textTheme.titleMedium),
            ),
            TextButton.icon(
              onPressed: reminders == null ? null : _add,
              icon: const Icon(LucideIcons.alarmClockPlus, size: 18),
              label: const Text('Frist hinzufügen'),
            ),
          ],
        ),
        if (reminders != null)
          for (final r in reminders)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: r.done,
              onChanged: (v) => _setDone(r, v ?? false),
              title: Text(
                r.note.isEmpty ? 'Frist' : r.note,
                style: r.done
                    ? const TextStyle(decoration: TextDecoration.lineThrough)
                    : null,
              ),
              subtitle: Text(
                formatDay(r.due),
                style: r.isDue()
                    ? TextStyle(color: theme.colorScheme.error)
                    : null,
              ),
              secondary: IconButton(
                tooltip: 'Frist löschen',
                icon: const Icon(LucideIcons.x, size: 18),
                onPressed: () => _delete(r),
              ),
            ),
      ],
    );
  }
}

/// Datum und Notiz für eine neue Frist.
Future<({DateTime due, String note})?> showReminderDialog(
  BuildContext context,
) {
  return showDialog<({DateTime due, String note})>(
    context: context,
    builder: (_) => const _ReminderDialog(),
  );
}

class _ReminderDialog extends StatefulWidget {
  const _ReminderDialog();

  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<_ReminderDialog> {
  final _note = TextEditingController();
  DateTime _due = DateUtils.dateOnly(
    DateTime.now().add(const Duration(days: 7)),
  );

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _due,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _due = picked);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Frist hinzufügen'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: _pickDate,
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Fällig am',
                prefixIcon: Icon(LucideIcons.calendar),
              ),
              child: Text(formatDay(_due)),
            ),
          ),
          TextField(
            controller: _note,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Notiz',
              hintText: 'z. B. Kündigungsfrist',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, (due: _due, note: _note.text.trim())),
          child: const Text('Hinzufügen'),
        ),
      ],
    );
  }
}
