import 'package:flutter/material.dart';

/// Kontextmenü für Passwortfelder (Rechtsklick, langes Drücken): bietet immer
/// „Einsetzen“ an, etwa aus einem Passwortmanager. Kopieren und Ausschneiden
/// bleiben bei verdeckten Feldern aus.
///
///     TextField(obscureText: true, contextMenuBuilder: passwordContextMenu)
Widget passwordContextMenu(BuildContext context, EditableTextState field) {
  final value = field.textEditingValue;
  final selected = value.selection.isValid
      ? value.selection.end - value.selection.start
      : 0;
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: field.contextMenuAnchors,
    buttonItems: [
      ContextMenuButtonItem(
        type: ContextMenuButtonType.paste,
        label: 'Einsetzen',
        onPressed: () => field.pasteText(SelectionChangedCause.toolbar),
      ),
      if (value.text.isNotEmpty && selected < value.text.length)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          label: 'Alles auswählen',
          onPressed: () => field.selectAll(SelectionChangedCause.toolbar),
        ),
      if (selected > 0)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.delete,
          label: 'Löschen',
          onPressed: () {
            field.userUpdateTextEditingValue(
              value.replaced(value.selection, ''),
              SelectionChangedCause.toolbar,
            );
            field.hideToolbar();
          },
        ),
    ],
  );
}
