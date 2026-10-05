import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'app_state.dart';
import 'screens/upload_screen.dart';
import 'upload_queue.dart';

/// Nimmt Dateien aus dem Teilen-Menü anderer Apps entgegen (iOS Share
/// Extension, Android Intents) und bietet sie zum Hochladen an.
class ShareIntake {
  ShareIntake(this.state, this.navigator);

  final AppState state;
  final GlobalKey<NavigatorState> navigator;
  StreamSubscription<List<SharedMediaFile>>? _sub;

  /// Geteilt, bevor die Anmeldung fertig war.
  List<SharedMediaFile>? _pending;

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android) &&
      // In Widget-Tests gibt es kein natives Plugin.
      !Platform.environment.containsKey('FLUTTER_TEST');

  void start() {
    if (!supported) return;
    state.addListener(_onState);
    try {
      _sub = ReceiveSharingIntent.instance.getMediaStream().listen(
        _handle,
        onError: (Object e) => debugPrint('Teilen nicht verfügbar: $e'),
      );
    } on MissingPluginException catch (e) {
      debugPrint('Teilen nicht verfügbar: $e');
      return;
    }
    _initial();
  }

  /// Dateien, mit denen die App gestartet wurde.
  Future<void> _initial() async {
    try {
      final files = await ReceiveSharingIntent.instance.getInitialMedia();
      await ReceiveSharingIntent.instance.reset();
      await _handle(files);
    } catch (e) {
      debugPrint('Teilen nicht verfügbar: $e');
    }
  }

  Future<void> _handle(List<SharedMediaFile> shared) async {
    final files = [
      for (final f in shared)
        if (f.type == SharedMediaType.file || f.type == SharedMediaType.image)
          f,
    ];
    if (files.isEmpty) return;
    if (state.status != SessionStatus.signedIn) {
      _pending = files;
      return;
    }
    final loaded = <({String name, Uint8List bytes})>[];
    for (final f in files) {
      final file = File(
        f.path.startsWith('file://') ? Uri.parse(f.path).toFilePath() : f.path,
      );
      if (await file.exists()) {
        loaded.add((
          name: p.basename(file.path),
          bytes: await file.readAsBytes(),
        ));
      }
    }
    if (loaded.isEmpty) return;
    final nav = navigator.currentState;
    if (loaded.length == 1 && nav != null) {
      await nav.push(
        MaterialPageRoute<bool>(
          builder: (_) => UploadScreen.file(
            fileName: loaded.single.name,
            fileBytes: loaded.single.bytes,
          ),
        ),
      );
    } else {
      state.uploads.add(state.client, [
        for (final f in loaded) UploadRequest(f.name, f.bytes),
      ]).ignore();
    }
  }

  void _onState() {
    final pending = _pending;
    if (pending != null && state.status == SessionStatus.signedIn) {
      _pending = null;
      // Erst nach dem Aufbau der Startseite navigieren.
      WidgetsBinding.instance.addPostFrameCallback((_) => _handle(pending));
    }
  }

  void dispose() {
    _sub?.cancel();
    state.removeListener(_onState);
  }
}
