import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../environment.dart';

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

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final client = state.client;
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
                if (client.server.serverVersion != null)
                  'Server ${client.server.serverVersion}',
                'API v${client.apiVersion}',
              ].join(' · '),
            ),
          ),
          ListTile(
            leading: const Icon(LucideIcons.tags),
            title: const Text('Stammdaten'),
            subtitle: Text(
              '${state.tags.length} Tags · ${state.correspondents.length} Korrespondenten · '
              '${state.documentTypes.length} Dokumenttypen',
            ),
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
