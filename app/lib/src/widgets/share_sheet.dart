import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import 'dialogs.dart';
import '../l10n.dart';

/// Eigentümer und Freigaben eines Dokuments bearbeiten.
/// Liefert das aktualisierte Dokument oder `null`.
Future<Document?> showShareSheet(BuildContext context, Document document) {
  return showModalBottomSheet<Document>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _ShareSheet(document: document),
  );
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.document});
  final Document document;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  ObjectPermissions? _perms;
  late int? _owner = widget.document.owner;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppScope.read(context).client
        .documentPermissions(widget.document.id)
        .then(
          (p) {
            if (mounted) setState(() => _perms = p);
          },
          onError: (Object e) {
            if (mounted) {
              setState(() => _error = e is ApiException ? e.message : '$e');
            }
          },
        );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final client = AppScope.read(context).client;
    final doc = await guarded(
      context,
      () => client.setDocumentPermissions(
        widget.document.id,
        _perms!,
        owner: _owner,
        setOwner: _owner != widget.document.owner,
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (doc != null) Navigator.pop(context, doc);
  }

  Widget _chips(String title, Map<int, String> options, Set<int> selected) {
    if (options.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in options.entries)
              FilterChip(
                label: Text(e.value),
                selected: selected.contains(e.key),
                onSelected: (v) => setState(
                  () => v ? selected.add(e.key) : selected.remove(e.key),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final me = state.client.user;
    final theme = Theme.of(context);
    final isOwner =
        me.isSuperuser ||
        widget.document.owner == null ||
        widget.document.owner == me.id;
    final users = {
      for (final u in state.users.values)
        if (u.id != _owner) u.id: u.displayName,
    };
    final groups = {for (final g in state.groups.values) g.id: g.name};
    final p = _perms;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr.sharePermissions, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              tr.withoutAnOwnerAllUsers,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            if (p == null && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (p != null) ...[
              if (!isOwner)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(LucideIcons.lock),
                  title: Text(tr.onlyTheOwnerCanChange),
                )
              else ...[
                if (state.users.isNotEmpty)
                  DropdownButtonFormField<int?>(
                    isExpanded: true,
                    initialValue: _owner,
                    decoration: InputDecoration(labelText: tr.owner),
                    items: [
                      DropdownMenuItem(
                        value: null,
                        child: Text(tr.noOwnerVisibleToEveryone),
                      ),
                      for (final u in state.users.values)
                        DropdownMenuItem(
                          value: u.id,
                          child: Text(u.displayName),
                        ),
                    ],
                    onChanged: (v) => setState(() => _owner = v),
                  ),
                const SizedBox(height: 16),
                _chips(tr.viewUsers, users, p.viewUsers),
                _chips(tr.viewGroups, groups, p.viewGroups),
                _chips(tr.changeUsers, users, p.changeUsers),
                _chips(tr.changeGroups, groups, p.changeGroups),
                if (users.isEmpty && groups.isEmpty)
                  Text(
                    tr.thereAreNoOtherUsers,
                    style: theme.textTheme.bodyMedium,
                  ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(tr.save),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Eigentümer und Freigaben für mehrere Dokumente auf einmal setzen.
/// Liefert `true`, wenn gespeichert wurde.
Future<bool> showBulkShareSheet(
  BuildContext context,
  List<int> documents,
) async {
  return await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => _BulkShareSheet(documents: documents),
      ) ??
      false;
}

class _BulkShareSheet extends StatefulWidget {
  const _BulkShareSheet({required this.documents});
  final List<int> documents;

  @override
  State<_BulkShareSheet> createState() => _BulkShareSheetState();
}

class _BulkShareSheetState extends State<_BulkShareSheet> {
  /// Eigentümer bleibt, wie er ist.
  static const _keepOwner = -2;

  final _perms = ObjectPermissions();
  int? _owner = _keepOwner;

  /// Freigaben ergänzen statt ersetzen.
  bool _merge = true;
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final client = AppScope.read(context).client;
    final ok = await guarded(
      context,
      () => client
          .bulkEdit(widget.documents, 'set_permissions', {
            'set_permissions': _perms.toJson(),
            if (_owner != _keepOwner) 'owner': _owner,
            'merge': _merge,
          })
          .then((_) => true),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok == true) Navigator.pop(context, true);
  }

  Widget _chips(String title, Map<int, String> options, Set<int> selected) {
    if (options.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in options.entries)
              FilterChip(
                label: Text(e.value),
                selected: selected.contains(e.key),
                onSelected: (v) => setState(
                  () => v ? selected.add(e.key) : selected.remove(e.key),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final users = {for (final u in state.users.values) u.id: u.displayName};
    final groups = {for (final g in state.groups.values) g.id: g.name};
    final n = widget.documents.length;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              n == 1
                  ? tr.permissionsForOneDocument
                  : tr.permissionsForDocuments(n),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            if (state.users.isNotEmpty) ...[
              DropdownButtonFormField<int?>(
                isExpanded: true,
                initialValue: _owner,
                decoration: InputDecoration(labelText: tr.owner),
                items: [
                  DropdownMenuItem(
                    value: _keepOwner,
                    child: Text(tr.leaveUnchanged),
                  ),
                  DropdownMenuItem(
                    value: null,
                    child: Text(tr.noOwnerVisibleToEveryone),
                  ),
                  for (final u in state.users.values)
                    DropdownMenuItem(value: u.id, child: Text(u.displayName)),
                ],
                onChanged: (v) => setState(() => _owner = v),
              ),
              const SizedBox(height: 16),
            ],
            _chips(tr.viewUsers, users, _perms.viewUsers),
            _chips(tr.viewGroups, groups, _perms.viewGroups),
            _chips(tr.changeUsers, users, _perms.changeUsers),
            _chips(tr.changeGroups, groups, _perms.changeGroups),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr.keepExistingPermissions),
              subtitle: Text(
                _merge
                    ? tr.theSelectedPermissionsAreAdded
                    : tr.theSelectedPermissionsReplaceThe,
              ),
              value: _merge,
              onChanged: (v) => setState(() => _merge = v),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(tr.save),
            ),
          ],
        ),
      ),
    );
  }
}
