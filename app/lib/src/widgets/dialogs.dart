import 'package:flutter/material.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

/// Rückfrage vor einer Aktion; liefert `true` bei Bestätigung.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  String? message,
  String action = 'OK',
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: message == null ? null : Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    )
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
}

void showError(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(error is ApiException ? error.message : '$error')),
  );
}

void showInfo(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Führt [action] aus und zeigt Fehler als Snackbar. Liefert das Ergebnis
/// oder `null` bei Fehlern.
Future<T?> guarded<T>(BuildContext context, Future<T> Function() action) async {
  try {
    return await action();
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
}

/// Einfacher Leerzustand für Verwaltungslisten.
class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}

/// Fragt einen kurzen Text ab; liefert ihn getrimmt oder `null`.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String? hint,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(title: title, label: label, hint: hint),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.title, required this.label, this.hint});
  final String title;
  final String label;
  final String? hint;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _text.text.trim();
    Navigator.pop(context, value.isEmpty ? null : value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _text,
      autofocus: true,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Speichern')),
    ],
  );
}

/// Auswahl zwischen mehreren Möglichkeiten; `null` = abgebrochen.
Future<T?> choose<T>(
  BuildContext context, {
  required String title,
  String? message,
  required List<(T, String)> options,
}) => showDialog<T>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: message == null ? null : Text(message),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      for (final (i, (value, label)) in options.indexed)
        i == options.length - 1
            ? FilledButton(
                onPressed: () => Navigator.pop(context, value),
                child: Text(label),
              )
            : TextButton(
                onPressed: () => Navigator.pop(context, value),
                child: Text(label),
              ),
    ],
  ),
);
