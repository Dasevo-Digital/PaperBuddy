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

## Paperless-Kompatibilität

Der Server meldet `X-Api-Version: 9` und `X-Version: 2.18.0` und akzeptiert
`Accept: application/json; version=1..9`. Vor Version 9 wird `created` als Zeitstempel
geliefert, ab 9 als Datum.

| Bereich | Status |
|---|---|
| `POST /api/token/`, Token- und Basic-Auth | ✅ |
| `ui_settings`, `profile`, `users`, `statistics`, `status`, `remote_version` | ✅ |
| Dokumente: Liste, Filter, Sortierung, `query` (FTS5), `fields`, `truncate_content` | ✅ |
| Dokumente: Detail, PATCH/PUT, DELETE, `download`, `preview`, `thumb`, `metadata`, `suggestions`, `notes`, `next_asn` | ✅ |
| `post_document` + `tasks` (inkl. acknowledge) | ✅ |
| `bulk_edit` (Tags, Korrespondent, Typ, Speicherpfad, Löschen) | ✅ teilweise |
| Tags, Korrespondenten, Dokumenttypen, Speicherpfade (CRUD) | ✅ |
| `search/autocomplete` | ✅ |
| `saved_views`, `custom_fields`, `share_links`, `workflows`, `mail_*`, `groups` | ⏳ leere Listen |
| Objektrechte (`set_permissions`), Papierkorb, Versionen/History | ⏳ |

## Roadmap

1. **MVP-Server** *(dieser Stand)*: API-Kern, Upload, Eingangsordner, OCR, Suche
2. **Test mit echten Apps**: Swift Paperless und Paperless Mobile gegen den Server, Lücken schließen
3. **Flutter-Client** (`app/`): Anmeldung, Liste, Suche, Filter, Upload *(erledigt)*;
   Bearbeiten, PDF-Ansicht, mobiles Scannen (VisionKit/ML Kit) folgen
4. **Automatik**: lernendes Matching (`auto`), Workflows, Gespeicherte Ansichten, Custom Fields
5. **Mehrbenutzer und Rechte**, Papierkorb, Freigabelinks
6. **Speicher-Backends** (S3, WebDAV/Nextcloud), Backup/Export, Import aus Paperless-ngx
7. **Eingänge**: Mail (IMAP), FTP, eSCL/AirScan
8. **Optional**: Postgres, Thumbnails als WebP, KI-Klassifizierung (lokal)
