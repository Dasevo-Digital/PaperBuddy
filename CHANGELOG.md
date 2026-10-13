# Änderungen

Hier steht je Version, was sich für Nutzer und Betreiber ändert. Die
ausführliche Fassung mit Hintergründen steht im jeweiligen Release.

## 0.4.0 (13.10.2026)

### Neu in der App

- **Suche nach Bedeutung:** Umschalter im Suchfeld (Funkeln-Symbol), sobald
  der Server eine lokale KI hat. Der Treffer zeigt den passenden Abschnitt.
- **Ähnliche Dokumente** in der Detailansicht.
- **Einstellungen → Lokale KI** zeigt den Zustand, Administratoren auch, wie
  viele Dokumente eingelesen sind.

### Neu im Server

- **Lokale KI** (optional, `PAPERBUDDY_AI=true`): Suche nach Bedeutung statt
  nach Wörtern, auch über Sprachgrenzen (`semantic_query`), und Zuordnung von
  Korrespondent, Dokumenttyp, Speicherpfad und Tags über die ähnlichsten
  Dokumente. Das Modell multilingual-e5-small (MIT) lädt der Server einmalig
  (135 MB, mit Prüfsummen), gerechnet wird mit ONNX Runtime auf dem eigenen
  Server. Docker-Image und Server-Paket bringen ONNX Runtime mit; für Server
  ohne Internet `manage ai-download`. Zustand unter `/api/ai/`.
- **Ähnliche Dokumente** über `more_like_id` wie bei Paperless-ngx (ohne KI
  über gemeinsame Wörter).

### Sonstiges

- Die CI testet die lokale KI mit dem echten Modell und nennt fehlgeschlagene
  App-Tests mit Namen; drei Tests, die auf dem CI-Rechner sporadisch
  fehlschlugen, warten jetzt auf das Ergebnis statt einer festen Zeit.

## 0.3.0 (11.10.2026)

### Neu in der App

- **Englische Oberfläche:** Die App spricht Deutsch und Englisch, je nach
  Gerät oder unter Einstellungen → Sprache. Datum und Zahlen folgen der
  Sprache, ebenso die Meldungen des API-Clients.
- **Zugriffe:** Wer ein Dokument angesehen, heruntergeladen oder über einen
  Freigabelink abgerufen hat, steht in der Detailansicht unter „Zugriffe“
  (für Eigentümer und Administratoren).
- **Zugriff für andere Apps:** Integrations-Token für Programme wie Famio
  anlegen und löschen (Einstellungen → Zugriff für andere Apps).

### Neu im Server

- **Rechnungsdaten:** Betrag, Rechnungsnummer, Fälligkeit und IBAN werden
  erkannt und in Custom Fields eingetragen – exakt aus E-Rechnungen
  (ZUGFeRD/Factur-X, XRechnung), sonst aus dem Text. XRechnung-Dateien (XML)
  lassen sich hochladen und erscheinen als lesbares PDF. Abschaltbar mit
  `PAPERBUDDY_INVOICE_FIELDS=false`, für vorhandene Dokumente
  `manage extract-invoices`.
- **Barcode-Trennblätter:** Stapelscans werden an Seiten mit dem Barcode
  `PATCHT` aufgeteilt, Barcodes wie `ASN00042` setzen die Archivnummer – mit
  denselben Einstellungen wie Paperless-ngx (`CONSUMER_ENABLE_BARCODES`,
  `CONSUMER_ENABLE_ASN_BARCODE`). Docker-Image und Debian-Installer bringen
  dafür `zbar-tools` mit.
- **Integrations-Token** (`/api/integration_tokens/`): nur lesen, nur
  Dokumente mit einem Tag samt deren Fristen, höchstens so viel, wie der
  Ersteller sieht.
- **Zugriffsprotokoll** (`/api/documents/<id>/access_log/`): abschaltbar mit
  `PAPERBUDDY_ACCESS_LOG=false`, Aufbewahrung `PAPERBUDDY_ACCESS_LOG_DAYS`
  (Standard 90 Tage).

### Betrieb

- **Sicherung:** täglich, verschlüsselt im age-Format und nach jedem Lauf
  geprüft (Prüfsummen, Datenbank zurückgespielt und gezählt), mit
  Aufbewahrung. Dazu `manage backup`, `verify-backup` und `restore-backup`;
  ohne PaperBuddy: `age -d <datei> | tar x`. Unter Debian schaltet
  `PAPERBUDDY_BACKUP=1 sh install.sh` sie ein.
- **Überwachung:** `/api/health/` für Uptime-Monitore, `/metrics` im
  Prometheus-Format und `/api/schema/` mit der OpenAPI-Beschreibung aller
  Endpunkte (Kopie in `docs/openapi.json`).
- **Integrationstests** der echten App gegen Wegwerf-Server, auch in der CI.

### Behoben

- Der Docker-Healthcheck schlug immer fehl, weil `/bin/sh` im Image `dash`
  ist und `/dev/tcp` nicht kennt; Container galten dadurch als „unhealthy“.
  Er fragt jetzt `/api/health/` über `bash` ab.
- Beim Abmelden blitzte kurz ein Fehlerbild auf.
- Nach einem falschen Zwei-Faktor-Code stand der Cursor nicht wieder im
  Codefeld.
- Neu angelegte Korrespondenten und Dokumenttypen erschienen im Formular als
  Nummer.
- „Vom Gerät entfernen“ in der Offline-Liste löste in Debug-Builds eine
  Assertion aus.

## 0.2.0 (09.10.2026)

### Neu in der App

- **Fristen:** An Dokumenten lassen sich Fristen anlegen, etwa
  „Kündigungsfrist 30.11.“. Die Übersicht zeigt die nächsten offenen Fristen,
  fällige erscheinen in der Benachrichtigungszentrale. Mit eingerichtetem
  Mailserver schickt der Server am Fälligkeitstag eine E-Mail
  (PaperBuddy-Erweiterung `/api/reminders/`).
- **Offline lesen:** Dokumente lassen sich für unterwegs auf dem Gerät
  behalten. Vorschaubilder und zuletzt geöffnete Dokumente bleiben
  zwischengespeichert (bis 300 MB); der belegte Platz steht in den
  Einstellungen.
- **App-Sperre** mit Face ID, Touch ID, Fingerabdruck oder Geräte-Code.
- **Vorschläge beim Bearbeiten** für Korrespondent, Tags, Dokumenttyp,
  Speicherpfad und Datum.
- **Gespeicherte Ansichten in der Übersicht** mit den fünf neuesten
  Dokumenten.
- **Mehr Mehrfachaktionen:** Speicherpfad, Freigaben, Drehen, neu
  verarbeiten, mehrere Dokumente teilen.
- **Suchvorschläge** beim Tippen in der Volltextsuche.
- **Darstellung** System, Hell oder Dunkel; das dunkle Design ist
  überarbeitet.
- Der Dateityp wird überall angezeigt; leere Felder blendet die
  Detailansicht aus.

### Verbessert

- Viele Uploads kurz hintereinander laden die Liste nur einmal neu, die Liste
  blitzt beim Aktualisieren nicht mehr auf, Vorschaubilder brauchen weniger
  Speicher, und nach der Rückkehr in die App wird abgeglichen.
- iPhone-Installation ohne bezahltes Apple-Entwicklerkonto (ohne Teilen-Menü).

### Sicherheit

- **Login-Bremse:** Nach wiederholt falschen Passwörtern antwortet der Server
  mit `429` und einer wachsenden Wartezeit, auch bei Basic-Auth. Hinter einem
  Reverse-Proxy dessen Adresse in `PAPERBUDDY_TRUSTED_PROXIES` eintragen.
- Vollständige Security-Header (CSP, Referrer-Policy, HSTS bei https), keine
  Angaben mehr zur verwendeten Technik.
- Docker-Basis-Images mit festem Digest.

### Sonstiges

- Lizenz: PolyForm Strict 1.0.0, Hinweise zu Komponenten Dritter in
  `THIRD_PARTY_NOTICES.md`.
- README mit Screenshots.

## 0.1.0 (05.10.2026)

Erste Version: Dokumentenserver mit Paperless-ngx-kompatibler REST-API (OCR,
Archiv-PDF, Zuordnung per Regel oder lernend, Workflows, Mail-Abruf,
Netzwerkscanner, Mehrbenutzer, S3 und WebDAV), Zwei-Faktor-Anmeldung und eine
Flutter-App für macOS, Android und iOS.
