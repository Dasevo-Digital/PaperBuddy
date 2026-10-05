# PaperBuddy

Selbst gehostete Dokumentenverwaltung in Dart/Flutter, inspiriert von Paperless-ngx.
Der Server spricht die **REST-API von Paperless-ngx**, dadurch funktionieren vorhandene
Apps wie Swift Paperless (iOS) oder Paperless Mobile direkt.

## Aufbau

| Ordner | Inhalt |
|---|---|
| `server/` | Dart-Server: API, Verarbeitung (OCR), Eingangsordner, SQLite |
| `app/` | Flutter-Client für iOS, Android, macOS, Windows, Linux und Web |
| `packages/paperbuddy_api/` | Gemeinsamer API-Client und Modelle (reines Dart) |
| `docs/` | Architektur und Roadmap |

## Server starten

### Nativ (macOS/Linux/Windows)

```bash
cd server
dart pub get
PAPERBUDDY_ADMIN_USER=admin PAPERBUDDY_ADMIN_PASSWORD=geheim123 \
PAPERBUDDY_CONSUMPTION_DIR=./consume dart run bin/server.dart
```

Für OCR und Vorschaubilder werden `ocrmypdf`, `tesseract` und `poppler` benötigt
(macOS: `brew install ocrmypdf tesseract-lang poppler`). Ohne sie werden Dateien
trotzdem übernommen, nur ohne Texterkennung.

Als eigenständige Binary samt SQLite: `dart build cli -t bin/server.dart` →
`build/cli/<plattform>/bundle/`.

### Docker (NAS/Server)

```bash
cp .env.example .env   # Passwörter setzen
docker compose up -d
```

Startet den Server auf Port 8000 und optional eine SMB-Freigabe `\\<host>\scans`
für Netzwerkscanner.

## Funktionen

- **Erfassen:** Upload (App, Web, API), Eingangsordner über SMB/FTP, E-Mail-Abruf per IMAP,
  Netzwerkscanner über eSCL/AirScan, Dokumentenscanner in der App (iOS VisionKit, Android ML Kit)
- **Verarbeiten:** OCR (ocrmypdf/Tesseract), Archiv-PDF, Vorschaubild, Datumserkennung,
  Zuordnung per Regel oder lernend, Workflows (Zuweisen, Entfernen, E-Mail, Webhook, zeitgesteuert)
- **Ordnen:** Tags, Korrespondenten, Dokumenttypen, Speicherpfade, Custom Fields, Notizen,
  Archivnummern, gespeicherte Ansichten, Volltextsuche
- **Teilen:** Mehrbenutzer mit Gruppen, Modell- und Objektrechten, Freigabelinks ohne Anmeldung
- **Sicherheit:** Papierkorb mit Frist, Export/Backup im Paperless-Format, Import aus Paperless-ngx
- **Speicher:** lokal, S3-kompatibel (AWS, MinIO, RustFS …) oder WebDAV (z. B. Nextcloud)

## Konfiguration

Umgebungsvariablen mit Präfix `PAPERBUDDY_`. Die `PAPERLESS_`-Namen werden ebenfalls erkannt.

| Variable | Standard | Bedeutung |
|---|---|---|
| `DATA_DIR` | `./data` | Datenbank, Arbeitsverzeichnis, Zwischenspeicher |
| `MEDIA_ROOT` | `$DATA_DIR/media` | Dateien bei lokalem Speicher |
| `CONSUMPTION_DIR` | – (aus) | Eingangsordner |
| `CONSUMER_POLLING` | `5` | Sekunden zwischen zwei Prüfungen des Eingangsordners |
| `OCR_LANGUAGE` | `deu+eng` | Tesseract-Sprachen |
| `PORT` / `BIND_ADDR` | `8000` / `0.0.0.0` | |
| `ADMIN_USER` / `ADMIN_PASSWORD` | – | legt beim ersten Start einen Admin an |
| `URL` | – | öffentliche Adresse (Links in E-Mails/Webhooks) |
| `CORS_ALLOWED_HOSTS` | – | kommagetrennte Origins für Web-Clients |
| `EMPTY_TRASH_DELAY` | `30` | Tage im Papierkorb |
| `MAIL_INTERVAL` | `10` | Minuten zwischen Mail-Abrufen, `0` = aus |
| `EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_HOST_USER`, `EMAIL_HOST_PASSWORD`, `EMAIL_FROM`, `EMAIL_USE_TLS`, `EMAIL_USE_SSL` | – | SMTP für Workflow-E-Mails |
| `SCANNERS` | – | feste eSCL-Scanner: `Büro=http://192.168.1.20/eSCL;…` |
| `SCANNER_DISCOVERY` | `true` | Scanner per mDNS suchen (in Docker `network_mode: host` nötig) |
| `STORAGE_BACKEND` | `local` | `local`, `s3` oder `webdav` |
| `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_PREFIX`, `S3_PATH_STYLE` | – | S3-Speicher (Bucket wird bei Bedarf angelegt) |
| `WEBDAV_URL`, `WEBDAV_USER`, `WEBDAV_PASSWORD` | – | WebDAV-Speicher |
| `STORAGE_CACHE_MB` | `500` | lokaler Zwischenspeicher bei S3/WebDAV |
| `DEBUG` | – | `1` = jede Anfrage loggen |

## Verwaltung auf der Kommandozeile

```bash
dart run bin/manage.dart createsuperuser
dart run bin/manage.dart export /pfad/zum/backup
dart run bin/manage.dart import /pfad/zum/paperless-export
dart run bin/manage.dart import-paperless https://paperless.example.org <api-token>
```

Im Container: `docker compose exec paperbuddy manage <befehl>`.

## Mit einer iOS-App verbinden

In Swift Paperless bzw. Paperless Mobile als Server-URL `http://<host>:8000` eintragen
und mit Benutzername/Passwort anmelden.

## App starten

```bash
cd app
tool/dev.sh macos        # „PaperBuddy Dev“: eigene Bundle-ID, eigener Schlüsselbund-Eintrag
tool/dev.sh ios          # bzw. android, web
flutter run -d macos     # normale App (Android: --flavor prod)
```

Für Tests und Probe-Builds immer die Dev-Variante nehmen, damit die installierte
App und ihre Anmeldung unberührt bleiben.

Die App verbindet sich mit PaperBuddy und mit Paperless-ngx. Der Token liegt im
Schlüsselspeicher des Systems; im Browser nur bis zum Schließen der Seite. Für die
Web-Version muss der Server die Herkunft erlauben, z. B.
`PAPERBUDDY_CORS_ALLOWED_HOSTS=http://localhost:8080`.

## Tests

```bash
cd server && dart test
cd packages/paperbuddy_api && dart test   # Client gegen den echten Server
cd app && flutter test                    # App-Logik und Oberfläche gegen den echten Server
```

Integrationstests gegen echte Dienste (S3, WebDAV, IMAP) starten die in
`server/test/integration_docker_test.dart` beschriebenen Container und laufen mit
`PAPERBUDDY_IT=1 dart test -t docker`.
