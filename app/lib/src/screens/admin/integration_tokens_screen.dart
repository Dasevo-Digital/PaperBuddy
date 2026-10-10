import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../../app_state.dart';
import '../../format.dart';
import '../../l10n.dart';
import '../../widgets/dialogs.dart';

/// Integrations-Token für andere Programme wie Famio: lesen nur Dokumente
/// mit einem Tag samt Fristen und sehen höchstens, was der Benutzer sieht.
class IntegrationTokensScreen extends StatefulWidget {
  const IntegrationTokensScreen({super.key});

  @override
  State<IntegrationTokensScreen> createState() => _IntegrationTokensScreenState();
}

class _IntegrationTokensScreenState extends State<IntegrationTokensScreen> {
  Future<List<IntegrationToken>>? _tokens;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tokens ??= AppScope.read(context).client.integrationTokens();
  }

  void _reload() {
    final tokens = AppScope.read(context).client.integrationTokens();
    setState(() {
      _tokens = tokens;
    });
  }

  Future<void> _create() async {
    final state = AppScope.read(context);
    final input = await showDialog<(String, int)>(
      context: context,
      builder: (_) => _CreateDialog(tags: state.tags.values.toList()),
    );
    if (input == null || !mounted) return;
    final created = await guarded(context, () => state.client.createIntegrationToken(input.$1, input.$2));
    if (created == null || !mounted) return;
    _reload();
    await showDialog<void>(context: context, builder: (_) => _KeyDialog(token: created.token ?? ''));
  }

  Future<void> _delete(IntegrationToken t) async {
    final ok = await confirm(
      context,
      title: tr.integrationDeleteQuestion,
      message: tr.integrationDeleteHint,
      action: tr.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await guarded(context, () => AppScope.read(context).client.deleteIntegrationToken(t.id));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.integrationsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(LucideIcons.keyRound),
        label: Text(tr.integrationCreate),
      ),
      body: FutureBuilder<List<IntegrationToken>>(
        future: _tokens,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          final tokens = snap.data;
          if (tokens == null) return const Center(child: CircularProgressIndicator());
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(tr.integrationsIntro, style: theme.textTheme.bodyMedium),
              ),
              if (tokens.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(tr.integrationsEmpty, style: theme.textTheme.bodySmall),
                ),
              for (final t in tokens)
                ListTile(
                  leading: const Icon(LucideIcons.keyRound),
                  title: Text(t.name),
                  subtitle: Text([
                    '${tr.integrationTag}: ${t.tagName ?? '#${t.tag}'}',
                    t.lastUsed == null ? tr.integrationNeverUsed : tr.integrationLastUsed(formatDayTime(t.lastUsed!)),
                  ].join(' · ')),
                  trailing: IconButton(
                    tooltip: tr.delete,
                    icon: const Icon(LucideIcons.trash2),
                    onPressed: () => _delete(t),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CreateDialog extends StatefulWidget {
  const _CreateDialog({required this.tags});
  final List<Tag> tags;

  @override
  State<_CreateDialog> createState() => _CreateDialogState();
}

class _CreateDialogState extends State<_CreateDialog> {
  final _name = TextEditingController(text: 'Famio');
  int? _tag;

  @override
  void initState() {
    super.initState();
    // Famio nimmt den Tag „Familie“, wenn es ihn gibt.
    _tag = widget.tags.where((t) => t.name.toLowerCase() == 'familie' || t.name.toLowerCase() == 'family').firstOrNull?.id;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _name.text.trim().isNotEmpty && _tag != null;
    return AlertDialog(
      title: Text(tr.integrationCreate),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: tr.name),
            onChanged: (_) => setState(() {}),
          ),
          DropdownButtonFormField<int>(
            initialValue: _tag,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr.integrationTag),
            items: [for (final t in widget.tags) DropdownMenuItem(value: t.id, child: Text(t.name))],
            onChanged: (v) => setState(() => _tag = v),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr.cancel)),
        FilledButton(
          onPressed: valid ? () => Navigator.pop(context, (_name.text.trim(), _tag!)) : null,
          child: Text(tr.integrationCreate),
        ),
      ],
    );
  }
}

/// Zeigt den Schlüssel einmalig zum Kopieren.
class _KeyDialog extends StatelessWidget {
  const _KeyDialog({required this.token});
  final String token;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr.integrationCreated),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text(tr.integrationKeyHint),
          SelectableText(token, style: const TextStyle(fontFamily: 'monospace')),
        ],
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(LucideIcons.copy),
          label: Text(tr.copyKey),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: token));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr.keyCopied)));
          },
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr.done)),
      ],
    );
  }
}
