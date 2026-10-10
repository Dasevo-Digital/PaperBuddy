import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';
import 'l10n.dart';

/// Gibt eine Datei weiter: auf dem Telefon über das Teilen-Menü, auf dem
/// Desktop und im Browser über „Speichern unter“ bzw. einen Download.
///
/// Liefert `false`, wenn der Benutzer abgebrochen hat.
Future<bool> exportFile(
  BuildContext context,
  Uint8List bytes,
  String fileName,
  String mimeType,
) async {
  final mobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);
  if (mobile) {
    // Das iPad braucht einen Ankerpunkt für das Popover.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: fileName, mimeType: mimeType)],
        fileNameOverrides: [fileName],
        sharePositionOrigin: origin,
      ),
    );
    return result.status != ShareResultStatus.dismissed;
  }
  final saved = await FilePicker.saveFile(
    fileName: fileName,
    bytes: bytes,
    mimeType: mimeType,
    dialogTitle: tr.saveDocument,
  );
  return saved != null || kIsWeb;
}

/// Mehrere Dateien weitergeben: auf dem Telefon gemeinsam über das
/// Teilen-Menü, auf dem Desktop in einen gewählten Ordner, im Browser als
/// einzelne Downloads. Gleiche Namen bekommen eine Nummer.
///
/// Liefert `false`, wenn der Benutzer abgebrochen hat.
Future<bool> exportFiles(
  BuildContext context,
  List<({Uint8List bytes, String fileName, String mimeType})> files,
) async {
  final names = <String>{};
  String unique(String name) {
    var candidate = name;
    final dot = name.lastIndexOf('.');
    final (base, ext) = dot > 0
        ? (name.substring(0, dot), name.substring(dot))
        : (name, '');
    for (var i = 2; !names.add(candidate); i++) {
      candidate = '$base ($i)$ext';
    }
    return candidate;
  }

  final named = [
    for (final f in files)
      (bytes: f.bytes, fileName: unique(f.fileName), mimeType: f.mimeType),
  ];
  final mobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);
  if (mobile) {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [
          for (final f in named)
            XFile.fromData(f.bytes, name: f.fileName, mimeType: f.mimeType),
        ],
        fileNameOverrides: [for (final f in named) f.fileName],
        sharePositionOrigin: origin,
      ),
    );
    return result.status != ShareResultStatus.dismissed;
  }
  if (kIsWeb) {
    for (final f in named) {
      await FilePicker.saveFile(
        fileName: f.fileName,
        bytes: f.bytes,
        mimeType: f.mimeType,
      );
    }
    return true;
  }
  final dir = await FilePicker.getDirectoryPath(
    dialogTitle: tr.chooseAFolderForThe,
  );
  if (dir == null) return false;
  for (final f in named) {
    await File('$dir/${f.fileName}').writeAsBytes(f.bytes);
  }
  return true;
}
