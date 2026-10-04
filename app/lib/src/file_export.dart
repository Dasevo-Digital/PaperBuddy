import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

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
    dialogTitle: 'Dokument speichern',
  );
  return saved != null || kIsWeb;
}
