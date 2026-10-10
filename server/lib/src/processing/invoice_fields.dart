import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../db.dart';
import 'invoice.dart';

/// Schreibt Rechnungsdaten in Custom Fields. Die Felder entstehen bei der
/// ersten Rechnung; welches Feld wofür steht, merkt sich `invoice_fields`,
/// sie lassen sich also umbenennen. Vorhandene Werte bleiben unangetastet.
class InvoiceFields {
  InvoiceFields(this.db);
  final Database db;

  /// Art → Name und Datentyp bei der Anlage.
  static const kinds = {
    'amount': ('Rechnungsbetrag', 'monetary'),
    'number': ('Rechnungsnummer', 'string'),
    'due': ('Fällig am', 'date'),
    'iban': ('IBAN', 'string'),
  };

  /// Feld zur Art; legt es bei Bedarf an oder übernimmt ein gleichnamiges.
  int fieldFor(String kind) {
    final known = db.select(
      'SELECT f.id FROM invoice_fields i JOIN custom_fields f ON f.id = i.field_id WHERE i.kind = ?',
      [kind],
    ).firstOrNull;
    if (known != null) return known['id'] as int;
    final (name, type) = kinds[kind]!;
    var id = db.select('SELECT id FROM custom_fields WHERE name = ? AND data_type = ?', [name, type]).firstOrNull?['id']
        as int?;
    if (id == null) {
      var unique = name;
      for (var i = 2; db.select('SELECT 1 FROM custom_fields WHERE name = ?', [unique]).isNotEmpty; i++) {
        unique = '$name ($i)';
      }
      db.execute(
        'INSERT INTO custom_fields (name, data_type, extra_data, created) VALUES (?, ?, ?, ?)',
        [unique, type, jsonEncode(type == 'monetary' ? {'default_currency': 'EUR'} : <String, Object?>{}), nowIso()],
      );
      id = db.lastInsertRowId;
    }
    db.execute('INSERT OR REPLACE INTO invoice_fields (kind, field_id) VALUES (?, ?)', [kind, id]);
    return id;
  }

  /// Trägt die gefundenen Werte ein; liefert die Anzahl neu gesetzter Felder.
  int apply(int documentId, InvoiceData data) {
    final values = <String, String?>{
      'amount': data.monetary,
      'number': data.number,
      'due': data.dueDate == null ? null : _dateOnly(data.dueDate!),
      'iban': data.iban,
    };
    var set = 0;
    for (final MapEntry(key: kind, value: value) in values.entries) {
      if (value == null) continue;
      final field = fieldFor(kind);
      final existing = db.select(
        'SELECT value FROM document_custom_fields WHERE document_id = ? AND field_id = ?',
        [documentId, field],
      ).firstOrNull;
      if (existing != null && existing['value'] != null) continue;
      db.execute(
        'INSERT INTO document_custom_fields (document_id, field_id, value) VALUES (?, ?, ?) '
        'ON CONFLICT (document_id, field_id) DO UPDATE SET value = excluded.value',
        [documentId, field, jsonEncode(value)],
      );
      set++;
    }
    return set;
  }
}

/// `YYYY-MM-DD` ohne Zeitzone.
String _dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
