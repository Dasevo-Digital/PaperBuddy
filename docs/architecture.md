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
3. **Flutter-Client** (`app/`): Web/Desktop zum Verwalten, Mobil mit Dokumentenscanner
   (VisionKit/ML Kit), gemeinsames Paket für Modelle und API-Client
4. **Automatik**: lernendes Matching (`auto`), Workflows, Gespeicherte Ansichten, Custom Fields
5. **Mehrbenutzer und Rechte**, Papierkorb, Freigabelinks
6. **Speicher-Backends** (S3, WebDAV/Nextcloud), Backup/Export, Import aus Paperless-ngx
7. **Eingänge**: Mail (IMAP), FTP, eSCL/AirScan
8. **Optional**: Postgres, Thumbnails als WebP, KI-Klassifizierung (lokal)
