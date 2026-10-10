import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../notifications.dart';
import '../screens/document_screen.dart';
import '../l10n.dart';

/// Glocke mit Zähler; öffnet die Benachrichtigungen als Pop-up (breit) bzw.
/// als Blatt von unten (Telefon).
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  final _menu = MenuController();

  void _open(NotificationCenter center) {
    if (MediaQuery.sizeOf(context).width < 600) {
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: NotificationList(center: center),
        ),
      ).then((_) => center.markAllSeen());
    } else {
      _menu.isOpen ? _menu.close() : _menu.open();
    }
  }

  @override
  Widget build(BuildContext context) {
    final center = AppScope.of(context).notifications;
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        final unread = center.unread;
        final running = center.hasRunning;
        return MenuAnchor(
          controller: _menu,
          alignmentOffset: const Offset(-300, 4),
          onClose: center.markAllSeen,
          menuChildren: [
            SizedBox(
              width: 380,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 480),
                child: NotificationList(center: center, menu: _menu),
              ),
            ),
          ],
          builder: (context, controller, _) => IconButton(
            tooltip: tr.notifications,
            onPressed: () => _open(center),
            icon: Badge(
              isLabelVisible: unread > 0 || running,
              label: running && unread == 0 ? null : Text('$unread'),
              smallSize: 8,
              child: Icon(running ? LucideIcons.bellDot : LucideIcons.bell),
            ),
          ),
        );
      },
    );
  }
}

/// Liste der Meldungen mit Entfernen und „Alle entfernen“.
class NotificationList extends StatelessWidget {
  const NotificationList({super.key, required this.center, this.menu});

  final NotificationCenter center;
  final MenuController? menu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        final notices = center.notices;
        final hasFinished = notices.any((n) => n.kind != NoticeKind.running);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr.notifications,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (hasFinished)
                    TextButton(
                      onPressed: center.clearFinished,
                      child: Text(tr.removeAll),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (notices.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  spacing: 8,
                  children: [
                    Icon(
                      LucideIcons.bellOff,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    Text(
                      tr.noNotifications,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                // Kein ListView: das Menü misst seine Breite vorab.
                child: SingleChildScrollView(
                  primary: false,
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final n in notices)
                        _NoticeTile(
                          notice: n,
                          unread: center.isUnread(n),
                          onDismiss: () => center.dismiss(n),
                          onOpen: n.documentId == null
                              ? null
                              : () {
                                  final state = AppScope.read(context);
                                  final navigator = Navigator.of(context);
                                  menu?.close();
                                  if (menu == null) navigator.pop();
                                  openDocument(state, navigator, n.documentId!);
                                },
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _NoticeTile extends StatelessWidget {
  const _NoticeTile({
    required this.notice,
    required this.unread,
    required this.onDismiss,
    this.onOpen,
  });

  final Notice notice;
  final bool unread;
  final VoidCallback onDismiss;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = DateFormat.Md().add_Hm().format(notice.time.toLocal());
    return ListTile(
      dense: true,
      tileColor: unread
          ? scheme.primaryContainer.withValues(alpha: 0.35)
          : null,
      leading: switch (notice.kind) {
        NoticeKind.running => const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        NoticeKind.success => Icon(
          LucideIcons.circleCheck,
          color: scheme.primary,
        ),
        NoticeKind.reminder => Icon(
          LucideIcons.alarmClock,
          color: scheme.error,
        ),
        NoticeKind.failure => Icon(
          LucideIcons.circleAlert,
          color: scheme.error,
        ),
      },
      title: Text(notice.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${notice.detail ?? ''} · $time',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onOpen,
      trailing: notice.kind == NoticeKind.running
          ? null
          : IconButton(
              tooltip: tr.remove,
              icon: const Icon(LucideIcons.x, size: 18),
              onPressed: onDismiss,
            ),
    );
  }
}

/// Öffnet ein Dokument aus einer Benachrichtigung.
Future<void> openDocument(
  AppState state,
  NavigatorState navigator,
  int id,
) async {
  try {
    final doc = await state.client.document(id);
    await navigator.push(
      MaterialPageRoute<void>(builder: (_) => DocumentScreen(document: doc)),
    );
  } catch (_) {
    // Inzwischen gelöscht oder keine Berechtigung.
  }
}
