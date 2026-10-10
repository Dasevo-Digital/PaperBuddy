import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../../app_state.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/text_menus.dart';
import '../../l10n.dart';

/// Bereiche für die Rechte-Matrix, mit Namen in der Sprache der App.
List<(String, String)> get permissionModels => [
  ('document', tr.documents),
  ('note', tr.notes),
  ('tag', 'Tags'),
  ('correspondent', tr.correspondents),
  ('documenttype', tr.documentTypes),
  ('storagepath', tr.storagePaths),
  ('customfield', 'Custom Fields'),
  ('savedview', tr.views),
  ('workflow', tr.workflows),
  ('mailaccount', tr.mailAccounts),
  ('mailrule', tr.mailRules),
  ('paperlesstask', tr.tasks),
  ('uisettings', tr.settings),
  ('sharelink', tr.shareLinks),
  ('user', tr.users),
  ('group', tr.groups),
];

const _actions = ['view', 'add', 'change', 'delete'];

/// Was ein normaler Benutzer zum Arbeiten mit Dokumenten braucht.
final defaultPermissions = <String>{
  for (final m in [
    'document',
    'note',
    'tag',
    'correspondent',
    'documenttype',
    'storagepath',
    'customfield',
    'savedview',
    'uisettings',
    'sharelink',
  ])
    for (final a in _actions) '${a}_$m',
  'view_paperlesstask',
  'change_paperlesstask',
};

class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _editUser([AppUser? user]) async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => UserEditScreen(user: user)));
    if (saved == true && mounted) await AppScope.read(context).refreshLabels();
  }

  Future<void> _editGroup([UserGroup? group]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => GroupEditScreen(group: group)),
    );
    if (saved == true && mounted) await AppScope.read(context).refreshLabels();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final me = state.client.user;
    final users = state.users.values.toList()
      ..sort((a, b) => a.username.compareTo(b.username));
    final groups = state.groups.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.usersAndGroups),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: tr.users),
            Tab(text: tr.groups),
          ],
        ),
      ),
      floatingActionButton: ListenableBuilder(
        listenable: _tabs,
        builder: (context, _) {
          final model = _tabs.index == 0 ? 'user' : 'group';
          if (!me.can('add', model)) return const SizedBox.shrink();
          return FloatingActionButton(
            tooltip: _tabs.index == 0 ? tr.createUser : tr.createGroup,
            onPressed: () => _tabs.index == 0 ? _editUser() : _editGroup(),
            child: const Icon(LucideIcons.plus),
          );
        },
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          ListView(
            children: [
              for (final u in users)
                ListTile(
                  leading: CircleAvatar(
                    child: Text(u.username.substring(0, 1).toUpperCase()),
                  ),
                  title: Text(u.displayName),
                  subtitle: Text(
                    [
                      u.username,
                      if (u.isSuperuser) tr.administrator,
                      if (u.isMfaEnabled) tr.twoFactor,
                      if (!u.isActive) 'deaktiviert',
                      if (u.groups.isNotEmpty)
                        u.groups
                            .map((g) => state.groups[g]?.name ?? '#$g')
                            .join(', '),
                    ].join(' · '),
                  ),
                  onTap: me.can('change', 'user') ? () => _editUser(u) : null,
                ),
            ],
          ),
          groups.isEmpty
              ? EmptyHint(
                  icon: LucideIcons.users,
                  text:
                      tr.noGroupsYetGroupsBundle,
                )
              : ListView(
                  children: [
                    for (final g in groups)
                      ListTile(
                        leading: const Icon(LucideIcons.users),
                        title: Text(g.name),
                        subtitle: Text(
                          tr.permissionsMembers(g.permissions.length, users.where((u) => u.groups.contains(g.id)).length),
                        ),
                        onTap: me.can('change', 'group')
                            ? () => _editGroup(g)
                            : null,
                      ),
                  ],
                ),
        ],
      ),
    );
  }
}

/// Rechte als Tabelle: Bereich × Ansehen/Anlegen/Ändern/Löschen.
class PermissionMatrix extends StatelessWidget {
  const PermissionMatrix({
    super.key,
    required this.selected,
    required this.onChanged,
    this.inherited = const {},
  });

  final Set<String> selected;
  final Set<String> inherited;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => onChanged({...defaultPermissions}),
              child: Text(tr.defaultLabel),
            ),
            OutlinedButton(
              onPressed: () =>
                  onChanged({for (final (m, _) in permissionModels) 'view_$m'}),
              child: Text(tr.readOnly),
            ),
            OutlinedButton(
              onPressed: () => onChanged({}),
              child: Text(tr.none),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 16,
            headingRowHeight: 36,
            dataRowMinHeight: 36,
            dataRowMaxHeight: 40,
            columns: [
              DataColumn(label: Text(tr.area)),
              DataColumn(label: Text(tr.view)),
              DataColumn(label: Text(tr.create)),
              DataColumn(label: Text(tr.change)),
              DataColumn(label: Text(tr.delete)),
            ],
            rows: [
              for (final (model, label) in permissionModels)
                DataRow(
                  cells: [
                    DataCell(Text(label)),
                    for (final a in _actions)
                      DataCell(
                        Checkbox(
                          value:
                              selected.contains('${a}_$model') ||
                              inherited.contains('${a}_$model'),
                          // Von Gruppen geerbte Rechte sind hier nicht abwählbar.
                          onChanged: inherited.contains('${a}_$model')
                              ? null
                              : (v) => onChanged(
                                  v == true
                                      ? {...selected, '${a}_$model'}
                                      : ({...selected}..remove('${a}_$model')),
                                ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        if (inherited.isNotEmpty)
          Text(
            tr.greyedOutCheckmarksComeFrom,
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }
}

class UserEditScreen extends StatefulWidget {
  const UserEditScreen({super.key, this.user});
  final AppUser? user;

  @override
  State<UserEditScreen> createState() => _UserEditScreenState();
}

class _UserEditScreenState extends State<UserEditScreen> {
  late final _username = TextEditingController(
    text: widget.user?.username ?? '',
  );
  late final _first = TextEditingController(text: widget.user?.firstName ?? '');
  late final _last = TextEditingController(text: widget.user?.lastName ?? '');
  late final _email = TextEditingController(text: widget.user?.email ?? '');
  final _password = TextEditingController();
  late bool _active = widget.user?.isActive ?? true;
  late bool _superuser = widget.user?.isSuperuser ?? false;
  late bool _mfa = widget.user?.isMfaEnabled ?? false;
  late final Set<int> _groups = {...?widget.user?.groups};
  late Set<String> _perms = widget.user == null
      ? {...defaultPermissions}
      : {...widget.user!.permissions};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_username, _first, _last, _email, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Set<String> _inherited(AppState state) => {
    for (final g in _groups) ...?state.groups[g]?.permissions,
  };

  Future<void> _save() async {
    if (_username.text.trim().isEmpty) {
      setState(() => _error = tr.pleaseEnterAUsername);
      return;
    }
    if (widget.user == null && _password.text.length < 8) {
      setState(() => _error = tr.thePasswordNeedsAtLeast);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final client = AppScope.read(context).client;
    final data = {
      'username': _username.text.trim(),
      'first_name': _first.text.trim(),
      'last_name': _last.text.trim(),
      'email': _email.text.trim(),
      'is_active': _active,
      'is_superuser': _superuser,
      'is_staff': _superuser,
      'groups': _groups.toList(),
      'user_permissions': _perms.toList(),
      if (_password.text.isNotEmpty) 'password': _password.text,
    };
    try {
      if (widget.user == null) {
        await client.createUser(data);
      } else {
        await client.updateUser(widget.user!.id, data);
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Etwa wenn das Telefon mit der Authenticator-App verloren ist.
  Future<void> _resetMfa() async {
    final ok = await confirm(
      context,
      title: tr.resetTwoFactorAuthentication,
      message:
          tr.theUserThenSignsIn,
      action: tr.reset,
      destructive: true,
    );
    if (!ok || !mounted) return;
    final done = await guarded(
      context,
      () => AppScope.read(
        context,
      ).client.deactivateUserTotp(widget.user!.id).then((_) => true),
    );
    if (done == true && mounted) {
      setState(() => _mfa = false);
      showInfo(context, tr.twoFactorAuthenticationReset);
    }
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: tr.deleteUser,
      message:
          tr.theirDocumentsAreKeptAnd,
      action: tr.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    final done = await guarded(
      context,
      () => AppScope.read(
        context,
      ).client.deleteUser(widget.user!.id).then((_) => true),
    );
    if (done == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final me = state.client.user;
    final isMe = widget.user?.id == me.id;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.user == null ? tr.createUser : widget.user!.username,
        ),
        actions: [
          if (widget.user != null && !isMe && me.can('delete', 'user'))
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
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  TextField(
                    controller: _username,
                    decoration: InputDecoration(
                      labelText: tr.username,
                    ),
                  ),
                  Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _first,
                          decoration: InputDecoration(
                            labelText: tr.firstName,
                          ),
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _last,
                          decoration: InputDecoration(
                            labelText: tr.lastName,
                          ),
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    controller: _email,
                    decoration: InputDecoration(labelText: tr.email),
                  ),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    contextMenuBuilder: passwordContextMenu,
                    decoration: InputDecoration(
                      labelText: widget.user == null
                          ? tr.password
                          : tr.newPassword,
                      helperText: widget.user == null
                          ? null
                          : tr.leaveEmptyToKeepIt,
                    ),
                  ),
                  if (widget.user != null && _mfa)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(LucideIcons.shieldCheck),
                      title: Text(tr.twoFactorAuthenticationActive),
                      trailing: !isMe && me.can('change', 'user')
                          ? TextButton(
                              onPressed: _resetMfa,
                              child: Text(tr.reset),
                            )
                          : null,
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr.active),
                    value: _active,
                    onChanged: isMe ? null : (v) => setState(() => _active = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr.administrator),
                    subtitle: Text(tr.mayDoEverythingAndSees),
                    value: _superuser,
                    onChanged: isMe || !me.isSuperuser
                        ? null
                        : (v) => setState(() => _superuser = v),
                  ),
                  if (state.groups.isNotEmpty) ...[
                    Text(
                      tr.groups,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final g in state.groups.values)
                          FilterChip(
                            label: Text(g.name),
                            selected: _groups.contains(g.id),
                            onSelected: (v) => setState(
                              () =>
                                  v ? _groups.add(g.id) : _groups.remove(g.id),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (!_superuser) ...[
                    Text(
                      tr.permissions,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    PermissionMatrix(
                      selected: _perms,
                      inherited: _inherited(state),
                      onChanged: (v) => setState(() => _perms = v),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GroupEditScreen extends StatefulWidget {
  const GroupEditScreen({super.key, this.group});
  final UserGroup? group;

  @override
  State<GroupEditScreen> createState() => _GroupEditScreenState();
}

class _GroupEditScreenState extends State<GroupEditScreen> {
  late final _name = TextEditingController(text: widget.group?.name ?? '');
  late Set<String> _perms = widget.group == null
      ? {...defaultPermissions}
      : {...widget.group!.permissions};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = tr.pleaseEnterAName);
      return;
    }
    setState(() => _saving = true);
    final client = AppScope.read(context).client;
    try {
      if (widget.group == null) {
        await client.createGroup(_name.text.trim(), _perms.toList());
      } else {
        await client.updateGroup(
          widget.group!.id,
          name: _name.text.trim(),
          permissions: _perms.toList(),
        );
      }
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
      title: tr.deleteGroup,
      action: tr.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    final done = await guarded(
      context,
      () => AppScope.read(
        context,
      ).client.deleteGroup(widget.group!.id).then((_) => true),
    );
    if (done == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final me = AppScope.of(context).client.user;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.group == null ? tr.createGroup : widget.group!.name,
        ),
        actions: [
          if (widget.group != null && me.can('delete', 'group'))
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
                  TextField(
                    controller: _name,
                    decoration: InputDecoration(
                      labelText: tr.name,
                      errorText: _error,
                    ),
                  ),
                  Text(
                    tr.membersPermissions,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  PermissionMatrix(
                    selected: _perms,
                    onChanged: (v) => setState(() => _perms = v),
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
