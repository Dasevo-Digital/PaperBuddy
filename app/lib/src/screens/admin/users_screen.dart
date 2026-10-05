import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../../app_state.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/text_menus.dart';

/// Bereiche für die Rechte-Matrix, mit deutschem Namen.
const permissionModels = <(String, String)>[
  ('document', 'Dokumente'),
  ('note', 'Notizen'),
  ('tag', 'Tags'),
  ('correspondent', 'Korrespondenten'),
  ('documenttype', 'Dokumenttypen'),
  ('storagepath', 'Speicherpfade'),
  ('customfield', 'Custom Fields'),
  ('savedview', 'Ansichten'),
  ('workflow', 'Workflows'),
  ('mailaccount', 'Mailkonten'),
  ('mailrule', 'Mailregeln'),
  ('paperlesstask', 'Aufgaben'),
  ('uisettings', 'Einstellungen'),
  ('sharelink', 'Freigabelinks'),
  ('user', 'Benutzer'),
  ('group', 'Gruppen'),
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
        title: const Text('Benutzer und Gruppen'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Benutzer'),
            Tab(text: 'Gruppen'),
          ],
        ),
      ),
      floatingActionButton: ListenableBuilder(
        listenable: _tabs,
        builder: (context, _) {
          final model = _tabs.index == 0 ? 'user' : 'group';
          if (!me.can('add', model)) return const SizedBox.shrink();
          return FloatingActionButton(
            tooltip: _tabs.index == 0 ? 'Benutzer anlegen' : 'Gruppe anlegen',
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
                      if (u.isSuperuser) 'Administrator',
                      if (u.isMfaEnabled) 'Zwei-Faktor',
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
              ? const EmptyHint(
                  icon: LucideIcons.users,
                  text:
                      'Noch keine Gruppen. Mit Gruppen lassen sich Rechte und Freigaben für mehrere Personen bündeln.',
                )
              : ListView(
                  children: [
                    for (final g in groups)
                      ListTile(
                        leading: const Icon(LucideIcons.users),
                        title: Text(g.name),
                        subtitle: Text(
                          '${g.permissions.length} Rechte · '
                          '${users.where((u) => u.groups.contains(g.id)).length} Mitglieder',
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
              child: const Text('Standard'),
            ),
            OutlinedButton(
              onPressed: () =>
                  onChanged({for (final (m, _) in permissionModels) 'view_$m'}),
              child: const Text('Nur lesen'),
            ),
            OutlinedButton(
              onPressed: () => onChanged({}),
              child: const Text('Keine'),
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
            columns: const [
              DataColumn(label: Text('Bereich')),
              DataColumn(label: Text('Ansehen')),
              DataColumn(label: Text('Anlegen')),
              DataColumn(label: Text('Ändern')),
              DataColumn(label: Text('Löschen')),
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
            'Ausgegraute Häkchen kommen aus Gruppen.',
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
      setState(() => _error = 'Bitte einen Benutzernamen angeben');
      return;
    }
    if (widget.user == null && _password.text.length < 8) {
      setState(() => _error = 'Das Passwort braucht mindestens 8 Zeichen');
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
      title: 'Zwei-Faktor-Anmeldung zurücksetzen?',
      message:
          'Der Benutzer meldet sich danach nur mit dem Passwort an und kann '
          'die Zwei-Faktor-Anmeldung im Profil neu einrichten.',
      action: 'Zurücksetzen',
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
      showInfo(context, 'Zwei-Faktor-Anmeldung zurückgesetzt');
    }
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: 'Benutzer löschen?',
      message:
          'Seine Dokumente bleiben erhalten und haben danach keinen Eigentümer mehr.',
      action: 'Löschen',
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
          widget.user == null ? 'Benutzer anlegen' : widget.user!.username,
        ),
        actions: [
          if (widget.user != null && !isMe && me.can('delete', 'user'))
            IconButton(
              tooltip: 'Löschen',
              icon: const Icon(LucideIcons.trash2),
              onPressed: _delete,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('Speichern'),
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
                    decoration: const InputDecoration(
                      labelText: 'Benutzername',
                    ),
                  ),
                  Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _first,
                          decoration: const InputDecoration(
                            labelText: 'Vorname',
                          ),
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _last,
                          decoration: const InputDecoration(
                            labelText: 'Nachname',
                          ),
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    controller: _email,
                    decoration: const InputDecoration(labelText: 'E-Mail'),
                  ),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    contextMenuBuilder: passwordContextMenu,
                    decoration: InputDecoration(
                      labelText: widget.user == null
                          ? 'Passwort'
                          : 'Neues Passwort',
                      helperText: widget.user == null
                          ? null
                          : 'Leer lassen, um es zu behalten',
                    ),
                  ),
                  if (widget.user != null && _mfa)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(LucideIcons.shieldCheck),
                      title: const Text('Zwei-Faktor-Anmeldung aktiv'),
                      trailing: !isMe && me.can('change', 'user')
                          ? TextButton(
                              onPressed: _resetMfa,
                              child: const Text('Zurücksetzen'),
                            )
                          : null,
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Aktiv'),
                    value: _active,
                    onChanged: isMe ? null : (v) => setState(() => _active = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Administrator'),
                    subtitle: const Text('Darf alles und sieht alle Dokumente'),
                    value: _superuser,
                    onChanged: isMe || !me.isSuperuser
                        ? null
                        : (v) => setState(() => _superuser = v),
                  ),
                  if (state.groups.isNotEmpty) ...[
                    Text(
                      'Gruppen',
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
                      'Rechte',
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
      setState(() => _error = 'Bitte einen Namen angeben');
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
      title: 'Gruppe löschen?',
      action: 'Löschen',
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
          widget.group == null ? 'Gruppe anlegen' : widget.group!.name,
        ),
        actions: [
          if (widget.group != null && me.can('delete', 'group'))
            IconButton(
              tooltip: 'Löschen',
              icon: const Icon(LucideIcons.trash2),
              onPressed: _delete,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('Speichern'),
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
                      labelText: 'Name',
                      errorText: _error,
                    ),
                  ),
                  Text(
                    'Rechte der Mitglieder',
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
