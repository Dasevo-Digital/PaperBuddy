import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'documents_screen.dart';
import 'settings_screen.dart';
import 'statistics_screen.dart';

/// Hauptnavigation: unten auf dem Telefon, seitlich ab Tablet-Breite.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  /// Hält Suche, Filter und Scrollposition, wenn die Navigation zwischen
  /// unten und seitlich wechselt (Fenstergröße, Drehen des Tablets).
  final _pagesKey = GlobalKey();

  static const _destinations = [
    (icon: LucideIcons.files, label: 'Dokumente'),
    (icon: LucideIcons.inbox, label: 'Posteingang'),
    (icon: LucideIcons.chartPie, label: 'Übersicht'),
    (icon: LucideIcons.settings, label: 'Einstellungen'),
  ];

  @override
  Widget build(BuildContext context) {
    final pages = [
      const DocumentsScreen(key: PageStorageKey('all'), title: 'Dokumente'),
      const DocumentsScreen(
        key: PageStorageKey('inbox'),
        title: 'Posteingang',
        baseFilter: DocumentFilter(inboxOnly: true),
      ),
      StatisticsScreen(
        onOpenDocuments: () => setState(() => _index = 0),
        onOpenInbox: () => setState(() => _index = 1),
      ),
      const SettingsScreen(),
    ];
    final body = IndexedStack(key: _pagesKey, index: _index, children: pages);
    final wide = MediaQuery.sizeOf(context).width >= 840;

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Icon(
                  LucideIcons.fileStack,
                  color: Theme.of(context).colorScheme.primary,
                  size: 32,
                ),
              ),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(icon: Icon(d.icon), label: d.label),
        ],
      ),
    );
  }
}
