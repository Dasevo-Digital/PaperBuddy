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

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Abmelden?'),
        content: const Text(
          'Die gespeicherte Anmeldung wird von diesem Gerät entfernt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Abmelden'),
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
            child: Text('Einstellungen', style: theme.textTheme.headlineSmall),
          ),
          ListTile(
            leading: const Icon(LucideIcons.user),
            title: Text(client.user.displayName ?? client.user.username),
            subtitle: Text(
              client.user.isSuperuser ? 'Administrator' : 'Benutzer',
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
              title: const Text('Darstellung'),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                    ),
                    ButtonSegment(value: ThemeMode.light, label: Text('Hell')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dunkel')),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) => state.setThemeMode(s.single),
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(LucideIcons.userCog),
            title: const Text('Profil'),
            subtitle: const Text('Name, E-Mail, Passwort'),
            onTap: () => _open(context, const ProfileScreen()),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Verwaltung', style: theme.textTheme.titleSmall),
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
              title: const Text('Workflows'),
              subtitle: const Text('Automatisch zuordnen, benachrichtigen'),
              onTap: () => _open(context, const WorkflowsScreen()),
            ),
          if (user.can('view', 'mailaccount'))
            ListTile(
              leading: const Icon(LucideIcons.mail),
              title: const Text('E-Mail-Abruf'),
              subtitle: const Text('Anhänge aus Postfächern übernehmen'),
              onTap: () => _open(context, const MailScreen()),
            ),
          if (user.can('view', 'user'))
            ListTile(
              leading: const Icon(LucideIcons.users),
              title: const Text('Benutzer und Gruppen'),
              subtitle: Text(
                '${state.users.length} Benutzer · ${state.groups.length} Gruppen',
              ),
              onTap: () => _open(context, const UsersScreen()),
            ),
          if (user.can('delete', 'document'))
            ListTile(
              leading: const Icon(LucideIcons.trash),
              title: const Text('Papierkorb'),
              onTap: () => _open(context, const TrashScreen()),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(LucideIcons.logOut),
            title: const Text('Abmelden'),
            onTap: () => _logout(context),
          ),
          const Divider(),
          AboutListTile(
            icon: const Icon(LucideIcons.info),
            applicationName: AppEnv.appName,
            applicationLegalese:
                'Dokumente verwalten mit PaperBuddy- und Paperless-ngx-Servern.',
          ),
        ],
      ),
    );
  }
}
