# Hinweise zu Komponenten und Diensten Dritter

PaperBuddy verwendet Komponenten Dritter. Sie behalten ihre jeweiligen Lizenz-
und Nutzungsbedingungen. Die Lizenzen der Dart- und Flutter-Pakete zeigt die App
zusätzlich in Flutters Lizenzübersicht an.

## Paperless-ngx

PaperBuddy bildet die REST-API von Paperless-ngx (GPL-3.0) nach, damit
vorhandene Apps weiter funktionieren. Code von Paperless-ngx oder Paperless
Mobile ist nicht übernommen.

## In der App enthalten

- PDFium über `pdfrx` — BSD-3-Clause/Apache-2.0; PDF-Anzeige
- Lucide-Symbole über `lucide_icons_flutter` — ISC
- Dokumentenscanner: VisionKit (iOS) und Google ML Kit Document Scanner
  (Android) unter den Bedingungen von Apple bzw. Google

## Im Server und im Docker-Image

- SQLite — Public Domain; über das Paket `sqlite3` eingebunden
- PointyCastle — MIT; scrypt und ChaCha20-Poly1305 für die Sicherungen
  im Dateiformat von age (https://age-encryption.org)
- OCRmyPDF — MPL-2.0
- Tesseract OCR mit Sprachdaten — Apache-2.0
- Poppler (`poppler-utils`) — GPL-2.0/GPL-3.0; als eigenständiges Programm
  aufgerufen
- qpdf — Apache-2.0
- LibreOffice (optional, `PAPERBUDDY_OFFICE=1`) — MPL-2.0; als eigenständiges
  Programm aufgerufen

Diese Programme werden bei der Installation aus den Paketquellen der
Distribution bezogen und nicht mit dem Quellcode ausgeliefert.

## Optionale Dienste und Container

- Samba-Container (`ghcr.io/servercontainers/samba`) und FTP-Container
  (`delfer/alpine-ftp-server`) in `docker-compose.yml` — nur bei Bedarf,
  unter ihren eigenen Lizenzen
- Gmail- und Outlook-Postfächer per OAuth, IMAP- und SMTP-Server, S3- und
  WebDAV-Speicher — nur nach Einrichtung durch den Betreiber

Selbst eingetragene Mail-, Speicher- und Anmeldedienste liegen in der
Verantwortung des jeweiligen PaperBuddy-Betreibers. Er muss deren Bedingungen
beachten.
