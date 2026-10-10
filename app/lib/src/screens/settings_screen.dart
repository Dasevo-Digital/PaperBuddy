import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../environment.dart';
import 'admin/custom_fields_screen.dart';
import 'admin/labels_screen.dart';
import 'admin/mail_screen.dart';
import 'admin/profile_screen.dart';
import 'admin/trash_screen.dart';
import 'admin/users_screen.dart';
import 'admin/workflows_screen.dart';
import 'offline_screen.dart';
import '../widgets/dialogs.dart';
import '../l10n.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.signOutQuestion),
        content: Text(
          tr.theSavedSignInWill,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.signOut),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) await AppScope.read(context).logout();
  }

  void _open(BuildContext context, Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final client = state.client;
    final user = client.user;
    final theme = Theme.of(context);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(tr.settings, style: theme.textTheme.headlineSmall),
          ),
          ListTile(
            leading: const Icon(LucideIcons.user),
            title: Text(client.user.displayName ?? client.user.username),
            subtitle: Text(
              client.user.isSuperuser ? tr.administrator : tr.users,
            ),
          ),
          ListTile(
            leading: const Icon(LucideIcons.server),
            title: Text(client.baseUrl.toString()),
            subtitle: Text(
              [
                if (client.server.paperbuddyVersion != null)
                  'PaperBuddy-Server ${client.server.paperbuddyVersion}'
                else if (client.server.serverVersion != null)
                  'Paperless-ngx ${client.server.serverVersion}',
                'API v${client.apiVersion}',
                'App ${AppEnv.version}',
              ].join(' · '),
            ),
          ),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: state.themeMode,
            builder: (context, mode, _) => ListTile(
              leading: const Icon(LucideIcons.sunMoon),
              title: Text(tr.appearance),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text(tr.system),
                    ),
                    ButtonSegment(value: ThemeMode.light, label: Text(tr.light)),
                    ButtonSegment(value: ThemeMode.dark, label: Text(tr.dark)),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) => state.setThemeMode(s.single),
                ),
              ),
            ),
          ),
          ValueListenableBuilder<String>(
            valueListenable: state.language,
            builder: (context, choice, _) => ListTile(
              leading: const Icon(LucideIcons.languages),
              title: Text(tr.settingsLanguage),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: 'system', label: Text(tr.system)),
                    for (final MapEntry(key: code, value: name) in appLanguages.entries)
                      ButtonSegment(value: code, label: Text(name)),
                  ],
                  selected: {appLanguages.containsKey(choice) ? choice : 'system'},
                  onSelectionChanged: (s) => state.setLanguage(s.single),
                ),
              ),
            ),
          ),
          const _AppLockTile(),
          if (state.files != null) ...[
            ListTile(
              leading: const Icon(LucideIcons.cloudCheck),
              title: Text(tr.availableOffline),
              subtitle: Text(tr.openDocumentsWithoutAConnection),
              onTap: () => _open(context, const OfflineScreen()),
            ),
            const _StorageTile(),
          ],
          ListTile(
            leading: const Icon(LucideIcons.userCog),
            title: Text(tr.profile),
            subtitle: Text(tr.nameEmailPassword),
            onTap: () => _open(context, const ProfileScreen()),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(tr.administration, style: theme.textTheme.titleSmall),
          ),
          for (final kind in LabelKind.values)
            if (user.can('view', kind.model))
              ListTile(
                leading: Icon(switch (kind) {
                  LabelKind.tag => LucideIcons.tags,
                  LabelKind.correspondent => LucideIcons.contact,
                  LabelKind.documentType => LucideIcons.fileType,
                  LabelKind.storagePath => LucideIcons.folderTree,
                }),
                title: Text(kind.plural),
                subtitle: Text(switch (kind) {
                  LabelKind.tag => '${state.tags.length}',
                  LabelKind.correspondent => '${state.correspondents.length}',
                  LabelKind.documentType => '${state.documentTypes.length}',
                  LabelKind.storagePath => '${state.storagePaths.length}',
                }),
                onTap: () => _open(context, LabelsScreen(kind: kind)),
              ),
          if (user.can('view', 'customfield'))
            ListTile(
              leading: const Icon(LucideIcons.textCursorInput),
              title: const Text('Custom Fields'),
              subtitle: Text('${state.customFields.length}'),
              onTap: () => _open(context, const CustomFieldsScreen()),
            ),
          if (user.can('view', 'workflow'))
            ListTile(
              leading: const Icon(LucideIcons.workflow),
              title: Text(tr.workflows),
              subtitle: Text(tr.assignAutomaticallyNotify),
              onTap: () => _open(context, const WorkflowsScreen()),
            ),
          if (user.can('view', 'mailaccount'))
            ListTile(
              leading: const Icon(LucideIcons.mail),
              title: Text(tr.emailImport),
              subtitle: Text(tr.importAttachmentsFromMailboxes),
              onTap: () => _open(context, const MailScreen()),
            ),
          if (user.can('view', 'user'))
            ListTile(
              leading: const Icon(LucideIcons.users),
              title: Text(tr.usersAndGroups),
              subtitle: Text(
                tr.usersGroups(state.users.length, state.groups.length),
              ),
              onTap: () => _open(context, const UsersScreen()),
            ),
          if (user.can('delete', 'document'))
            ListTile(
              leading: const Icon(LucideIcons.trash),
              title: Text(tr.trash),
              onTap: () => _open(context, const TrashScreen()),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(LucideIcons.logOut),
            title: Text(tr.signOut),
            onTap: () => _logout(context),
          ),
          const Divider(),
          AboutListTile(
            icon: const Icon(LucideIcons.info),
            applicationName: AppEnv.appName,
            applicationLegalese:
                tr.manageDocumentsWithPaperbuddyAnd,
          ),
        ],
      ),
    );
  }
}

/// Belegter Gerätespeicher; „Leeren“ entfernt Vorschaubilder und zuletzt
/// geöffnete Dokumente, offline gespeicherte bleiben.
class _StorageTile extends StatefulWidget {
  const _StorageTile();

  @override
  State<_StorageTile> createState() => _StorageTileState();
}

class _StorageTileState extends State<_StorageTile> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final n = await AppScope.read(context).files?.sizeInBytes();
    if (mounted) setState(() => _bytes = n);
  }

  Future<void> _clear() async {
    final state = AppScope.read(context);
    await state.files?.clearTemporary();
    state.thumbnails.clear();
    await _measure();
  }

  @override
  Widget build(BuildContext context) {
    final mb = _bytes == null
        ? '…'
        : (_bytes! / (1024 * 1024)).toStringAsFixed(1);
    return ListTile(
      leading: const Icon(LucideIcons.hardDrive),
      title: Text(tr.storageOnThisDevice),
      subtitle: Text(tr.mbForPreviewsAndDocuments(mb)),
      trailing: TextButton(onPressed: _clear, child: Text(tr.empty)),
    );
  }
}

/// Schalter für die App-Sperre; nur, wenn das Gerät sie unterstützt.
class _AppLockTile extends StatefulWidget {
  const _AppLockTile();

  @override
  State<_AppLockTile> createState() => _AppLockTileState();
}

class _AppLockTileState extends State<_AppLockTile> {
  late final Future<bool> _supported = AppScope.read(context).lock.supported;

  @override
  Widget build(BuildContext context) {
    final lock = AppScope.of(context).lock;
    return FutureBuilder<bool>(
      future: _supported,
      builder: (context, snap) {
        if (snap.data != true) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: lock,
          builder: (context, _) => SwitchListTile(
            secondary: const Icon(LucideIcons.lock),
            title: Text(tr.appLock),
            subtitle: Text(
              tr.unlockWithFaceIdTouch,
            ),
            value: lock.enabled,
            onChanged: (v) async {
              final ok = await lock.setEnabled(v);
              if (!ok && context.mounted) {
                showInfo(context, tr.theCheckWasCancelled);
              }
            },
          ),
        );
      },
    );
  }
}
