# Architektur

## Grundsatzentscheidung

**Server/Client**, wobei der Server klein genug ist, um auch lokal auf dem Mac zu laufen.
„Lokal mit Cloudspeicher“ ist damit eine Frage der Bereitstellung:

- Netzwerkscanner brauchen ein Ziel, das immer erreichbar ist (SMB/FTP/E-Mail).
- Die Paperless-iOS-Apps brauchen eine HTTP-API.
- Fernzugriff läuft über Reverse Proxy oder VPN (z. B. Tailscale) auf diesen Server.
- Speicher-Backends sind austauschbar (`BlobStore`: lokal, später S3/WebDAV).

Server in **Dart**, damit Modelle und API-Code mit dem Flutter-Client geteilt werden können.
OCR läuft über externe Programme (`ocrmypdf`/Tesseract, Poppler).

```
 Scanner ──SMB──▶ Eingangsordner ─┐
 iOS-Apps / Flutter ──HTTP──▶ API ┼─▶ Consumer-Warteschlange ─▶ OCR, Text, Thumbnail,
                                  │                              Matching, Datum
                                  └─▶ SQLite (+FTS5) ◀── BlobStore (Dateien)
```

## Server-Module (`server/lib/src`)

| Datei | Aufgabe |
|---|---|
| `config.dart` | Umgebungsvariablen |
| `db.dart` | SQLite-Schema und Migrationen (`PRAGMA user_version`), FTS5-Index per Trigger |
| `auth.dart` | Benutzer, Token, Basic Auth; Passwort-Hashes im Django-Format (übernehmbar aus Paperless) |
| `storage.dart` | `BlobStore`-Abstraktion, `LocalBlobStore` |
| `processing/consumer.dart` | Warteschlange: Duplikatprüfung (MD5), OCR, Text, Vorschau, Matching, Ablage, Tasks |
| `processing/consume_folder.dart` | Polling des Eingangsordners (SMB-tauglich, wartet auf fertig geschriebene Dateien) |
| `processing/matching.dart` | Matching-Algorithmen wie in Paperless (any/all/literal/regex/fuzzy), Datumserkennung |
| `processing/tools.dart` | Aufrufe von ocrmypdf, tesseract, pdftotext, pdftoppm, pdfinfo |
| `api/paperless_api.dart` | Router, Middleware (Auth, CORS, Versions-Header), allgemeine Endpunkte |
| `api/documents.dart` | Dokumente: Liste/Filter/Suche, Upload, Download, Vorschau, Notizen, Bulk-Edit |
| `api/taxonomy.dart` | CRUD für Tags, Korrespondenten, Dokumenttypen, Speicherpfade |

## Client (`packages/paperbuddy_api`, `app/`)

`paperbuddy_api` ist reines Dart und spricht ausschließlich die Paperless-API. Beim
Verbinden fragt der Client ohne Versionsangabe an, liest `X-Api-Version` und nutzt
danach `min(Server, 9)`. Dadurch funktioniert er auch mit älteren Paperless-ngx-Servern.

Die Flutter-App nutzt wie Famio keinen State-Management-Rahmen: `AppState`
(`ChangeNotifier`) hält Sitzung und Stammdaten, Screens greifen über `AppScope` darauf zu.

| Datei | Aufgabe |
|---|---|
| `app_state.dart` | Anmelden, Sitzung wiederherstellen, Stammdaten, Upload-Warteschlange |
| `session_store.dart` | Token im Schlüsselspeicher, ein einziger Eintrag je Variante (prod/dev) |
| `documents_controller.dart` | Seitenweises Laden der Liste für einen Filter, verwirft veraltete Antworten |
| `thumbnail_cache.dart` | Vorschaubilder über den API-Client (im Browser schickt `Image.network` keine Auth-Header) |
| `upload_queue.dart` | Uploads nacheinander, Verarbeitung über `/api/tasks/` verfolgen |
| `screens/` | Anmeldung, Navigation (unten bzw. seitlich ab 840 px), Liste, Detail, Einstellungen |

Die Tests in `app/test` und `packages/paperbuddy_api/test` laufen gegen den echten
Server im selben Prozess (ohne Netzwerk, über einen Shelf-Handler).

## Weitere Server-Module

| Datei | Aufgabe |
|---|---|
| `access.dart` | Modellrechte (`view_document` …) und Objektrechte (Eigentümer, Freigaben); SQL-Bedingungen für sichtbare/änderbare Objekte |
| `trash.dart` | Papierkorb, automatisches Leeren |
| `workflows.dart` | Workflow-Engine (Auslöser, Aktionen, Platzhalter, Zeitsteuerung) und API |
| `processing/classifier.dart` | Lernendes Matching (Naive Bayes), stündlich nachtrainiert |
| `mail/` | IMAP-Client, MIME-Parser, Mailkonten und -regeln |
| `scanners/escl.dart` | eSCL/AirScan: Suche per mDNS, Fähigkeiten, Scanaufträge |
| `storage_remote.dart` | S3 (SigV4) und WebDAV mit lokalem Zwischenspeicher |
| `transfer.dart` | Export/Import im Paperless-Format, Direktübernahme per API |
| `api/users.dart`, `custom_fields.dart`, `saved_views.dart`, `share_links.dart` | weitere Endpunkte |

## Paperless-Kompatibilität

Der Server meldet `X-Api-Version: 9` und `X-Version: 2.18.0` und akzeptiert
`Accept: application/json; version=1..9`. Vor Version 9 wird `created` als Zeitstempel
geliefert, ab 9 als Datum. Abgeglichen mit dem Quellcode von Swift Paperless
(Endpunkte und Pflichtfelder aller genutzten Datenmodelle).

Umgesetzt: Token-/Basic-Auth, Dokumente mit allen gängigen Filtern, Volltextsuche,
`custom_field_query`, Upload und Tasks, Bulk-Edit (Tags, Korrespondent, Typ, Speicherpfad,
Custom Fields, Rechte, Löschen, Neuverarbeitung), Notizen, Vorschläge, Tags/Korrespondenten/
Dokumenttypen/Speicherpfade, Custom Fields, gespeicherte Ansichten, Benutzer, Gruppen, Profil,
Papierkorb, Workflows, Mailkonten und -regeln, Freigabelinks, `bulk_edit_objects`,
`ui_settings`, `statistics`, `status`, `config`, `remote_version`, `search/autocomplete`.

Nicht umgesetzt: PDF-Bearbeitung per Bulk-Edit (`rotate`, `merge`, `split`, `delete_pages`),
Dokumentversionen/History, Speicherpfade als Ordnerstruktur auf der Platte, OAuth für Mailkonten,
API v10 (Paperless 3.x).

## Roadmap

1. **MVP-Server**: API-Kern, Upload, Eingangsordner, OCR, Suche *(erledigt)*
2. **Test mit echten Apps**: Swift Paperless und Paperless Mobile gegen den Server, Lücken schließen
3. **Flutter-Client** (`app/`): Liste, Suche, Bearbeiten, PDF-Ansicht, Scannen, Verwaltung *(erledigt)*
4. **Automatik**: lernendes Matching (`auto`), Workflows, Gespeicherte Ansichten, Custom Fields *(erledigt)*
5. **Mehrbenutzer und Rechte**, Papierkorb, Freigabelinks *(erledigt)*
6. **Speicher-Backends** (S3, WebDAV/Nextcloud), Backup/Export, Import aus Paperless-ngx *(erledigt)*
7. **Eingänge**: Mail (IMAP), FTP, eSCL/AirScan *(erledigt)*
8. **Optional**: Postgres, Thumbnails als WebP, KI-Klassifizierung (lokal)
