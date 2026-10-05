#!/bin/sh
# Installiert oder aktualisiert PaperBuddy auf Debian/Ubuntu (z. B. in einem
# Proxmox-LXC). Als root im entpackten Paket ausführen:
#
#   sh install.sh                    # aus dem aktuellen Ordner
#   sh install.sh paket.tar.gz       # Tarball entpacken und installieren
#
# Beim ersten Lauf wird ein Administrator mit Zufallspasswort angelegt; das
# Passwort steht danach in /root/paperbuddy-admin.txt. Bei späteren Läufen
# bleiben Daten (/var/lib/paperbuddy) und Konfiguration
# (/etc/paperbuddy/paperbuddy.env) erhalten, die vorige Version liegt in
# /opt/paperbuddy.old.
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausführen." >&2
  exit 1
fi

src="$(cd "$(dirname "$0")" && pwd)"
if [ $# -gt 0 ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  tar -C "$tmp" -xzf "$1"
  src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
fi
[ -x "$src/bin/server" ] || { echo "Kein Server-Paket in $src" >&2; exit 1; }

echo "Pakete installieren …"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
  ca-certificates curl ocrmypdf poppler-utils qpdf \
  tesseract-ocr tesseract-ocr-deu tesseract-ocr-eng
# PAPERBUDDY_OFFICE=1 sh install.sh: LibreOffice für Vorschau und Archiv-PDF
# von Word, Excel und PowerPoint (rund 400 MB). Einmal installiert, bleibt es.
if [ "${PAPERBUDDY_OFFICE:-0}" = 1 ]; then
  apt-get install -y -q --no-install-recommends \
    libreoffice-writer-nogui libreoffice-calc-nogui libreoffice-impress-nogui \
    fonts-dejavu-core fonts-liberation2
fi

if ! id paperbuddy >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/paperbuddy --shell /usr/sbin/nologin paperbuddy
fi
install -d -o paperbuddy -g paperbuddy -m 0750 /var/lib/paperbuddy
install -d -o paperbuddy -g paperbuddy -m 0770 /var/lib/paperbuddy/consume
install -d -m 0750 -g paperbuddy /etc/paperbuddy

env=/etc/paperbuddy/paperbuddy.env
if [ ! -f "$env" ]; then
  password="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"
  umask 077
  cat > "$env" <<EOF
# PaperBuddy – Umgebungsvariablen (siehe README, Abschnitt Konfiguration)
PAPERBUDDY_DATA_DIR=/var/lib/paperbuddy
PAPERBUDDY_CONSUMPTION_DIR=/var/lib/paperbuddy/consume
PAPERBUDDY_PORT=8000
PAPERBUDDY_OCR_LANGUAGE=deu+eng
TZ=Europe/Berlin
# Nur beim allerersten Start ausgewertet, solange es noch keine Benutzer gibt.
PAPERBUDDY_ADMIN_USER=admin
PAPERBUDDY_ADMIN_PASSWORD=$password
# Optional:
# PAPERBUDDY_URL=https://docs.example.org
# PAPERBUDDY_SCANNERS=Büro=http://192.0.2.20/eSCL
# PAPERBUDDY_FILENAME_FORMAT={{ created_year }}/{{ correspondent }}/{{ title }}
EOF
  printf 'Benutzer: admin\nPasswort: %s\n' "$password" > /root/paperbuddy-admin.txt
  chmod 0600 /root/paperbuddy-admin.txt
  chgrp paperbuddy "$env"
  chmod 0640 "$env"
  umask 022
  echo "Administrator angelegt, Zugangsdaten in /root/paperbuddy-admin.txt"
fi

if systemctl is-active --quiet paperbuddy; then
  systemctl stop paperbuddy
fi
if [ -d /opt/paperbuddy ]; then
  rm -rf /opt/paperbuddy.old
  mv /opt/paperbuddy /opt/paperbuddy.old
fi
mkdir -p /opt/paperbuddy
cp -R "$src/bin" "$src/lib" /opt/paperbuddy/
[ -f "$src/VERSION" ] && cp "$src/VERSION" /opt/paperbuddy/
chmod -R a+rX /opt/paperbuddy
# Verwaltung (export, import, createsuperuser …) mit derselben Konfiguration
# und als Dienstbenutzer, damit neue Dateien ihm gehören.
cat > /usr/local/bin/paperbuddy-manage <<'EOF'
#!/bin/sh
set -a
. /etc/paperbuddy/paperbuddy.env
set +a
cd /var/lib/paperbuddy
exec runuser -u paperbuddy --preserve-environment -- /opt/paperbuddy/bin/manage "$@"
EOF
chmod 0755 /usr/local/bin/paperbuddy-manage

install -m 0644 "$src/paperbuddy.service" /etc/systemd/system/paperbuddy.service
systemctl daemon-reload
systemctl enable --now paperbuddy

printf 'Warte auf den Server '
i=0
until curl -s -o /dev/null http://127.0.0.1:8000/api/; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo
    echo "Server antwortet nicht. Log: journalctl -u paperbuddy -n 50" >&2
    exit 1
  fi
  printf '.'
  sleep 1
done
echo " läuft."
echo "PaperBuddy $(cat /opt/paperbuddy/VERSION 2>/dev/null || true) auf Port 8000."
