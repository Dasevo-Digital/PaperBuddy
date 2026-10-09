# Änderungen

Hier steht je Version, was sich für Nutzer und Betreiber ändert. Die
ausführliche Fassung mit Hintergründen steht im jeweiligen Release.

## 0.2.0 (in Vorbereitung)

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
