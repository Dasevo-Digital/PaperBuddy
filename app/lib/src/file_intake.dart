import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'app_state.dart';
import 'screens/upload_screen.dart';
import 'upload_queue.dart';

typedef IncomingFile = ({String name, Uint8List bytes});

/// Nimmt Dateien von außen entgegen (Teilen-Menü, Drag & Drop): eine Datei
/// öffnet „Neues Dokument“ zum Ergänzen von Titel und Tags, mehrere landen
/// direkt in der Upload-Warteschlange.
Future<void> offerFiles(
  AppState state,
  NavigatorState? navigator,
  List<IncomingFile> files,
) async {
  if (files.isEmpty || state.status != SessionStatus.signedIn) return;
  if (files.length == 1 && navigator != null) {
    await navigator.push(
      MaterialPageRoute<bool>(
        builder: (_) => UploadScreen.file(
          fileName: files.single.name,
          fileBytes: files.single.bytes,
        ),
      ),
    );
  } else {
    state.uploads.add(state.client, [
      for (final f in files) UploadRequest(f.name, f.bytes),
    ]).ignore();
  }
}

/// Dateien aus dem Finder/Explorer auf das Fenster ziehen, um sie
/// hochzuladen (macOS, Windows, Linux, Web).
class DropZone extends StatefulWidget {
  const DropZone({super.key, required this.navigator, required this.child});

  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  static bool get supported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  State<DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<DropZone> {
  bool _hovering = false;

  Future<void> _dropped(DropDoneDetails details) async {
    setState(() => _hovering = false);
    final state = AppScope.read(context);
    final files = <IncomingFile>[];
    var skipped = 0;
    for (final item in details.files) {
      try {
        final bytes = await item.readAsBytes();
        if (bytes.isEmpty) {
          skipped++;
          continue;
        }
        files.add((name: item.name, bytes: bytes));
      } catch (_) {
        // Ordner oder nicht lesbare Dateien.
        skipped++;
      }
    }
    if (skipped > 0) {
      final messenger = widget.navigator.currentContext == null
          ? null
          : ScaffoldMessenger.maybeOf(widget.navigator.currentContext!);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            skipped == 1
                ? 'Ein Eintrag wurde übersprungen (Ordner oder nicht lesbar).'
                : '$skipped Einträge wurden übersprungen (Ordner oder nicht lesbar).',
          ),
        ),
      );
    }
    await offerFiles(state, widget.navigator.currentState, files);
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = AppScope.of(context).status == SessionStatus.signedIn;
    if (!DropZone.supported || !signedIn) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: _dropped,
      child: Stack(
        children: [
          widget.child,
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: Material(
                  color: scheme.primary.withValues(alpha: 0.12),
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.primary, width: 3),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 12,
                            children: [
                              Icon(
                                LucideIcons.fileUp,
                                color: scheme.primary,
                                size: 32,
                              ),
                              Text(
                                'Loslassen, um hochzuladen',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
