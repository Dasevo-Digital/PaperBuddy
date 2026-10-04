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

## Konfiguration

Umgebungsvariablen mit Präfix `PAPERBUDDY_`. Die `PAPERLESS_`-Namen werden ebenfalls erkannt.

| Variable | Standard | Bedeutung |
|---|---|---|
| `DATA_DIR` | `./data` | Datenbank, Arbeitsverzeichnis |
| `MEDIA_ROOT` | `$DATA_DIR/media` | Originale, Archiv-PDFs, Vorschaubilder |
| `CONSUMPTION_DIR` | – (aus) | Eingangsordner |
| `CONSUMER_POLLING` | `5` | Sekunden zwischen zwei Prüfungen des Eingangsordners |
| `OCR_LANGUAGE` | `deu+eng` | Tesseract-Sprachen |
| `PORT` / `BIND_ADDR` | `8000` / `0.0.0.0` | |
| `ADMIN_USER` / `ADMIN_PASSWORD` | – | legt beim ersten Start einen Admin an |
| `CORS_ALLOWED_HOSTS` | – | kommagetrennte Origins für Web-Clients |
| `DEBUG` | – | `1` = jede Anfrage loggen |

Weitere Admins anlegen: `dart run bin/manage.dart createsuperuser`
(im Container: `docker compose exec paperbuddy manage createsuperuser`).

## Mit einer iOS-App verbinden

In Swift Paperless bzw. Paperless Mobile als Server-URL `http://<host>:8000` eintragen
und mit Benutzername/Passwort anmelden.

## App starten

```bash
cd app
flutter run -d macos                                  # oder ios, android, chrome …
flutter run -d macos --dart-define=PAPERBUDDY_ENV=dev # Dev-Variante mit eigenem Schlüsselbund-Eintrag
```

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
