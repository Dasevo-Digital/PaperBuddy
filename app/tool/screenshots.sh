#!/usr/bin/env bash
# Erzeugt die README-Screenshots (docs/screenshots) mit ausgedachten
# Demo-Dokumenten: ein frischer Server im Container (mit OCR und
# Vorschaubildern) und die echte App mit eigener Bundle-ID, deren Sitzung im
# Arbeitsspeicher bleibt. Installierte Apps und ihre Daten bleiben unberührt.
#
#   tool/screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."
port=18090
password="demo-$(openssl rand -hex 8)"
log="$(mktemp)"
container=paperbuddy-shots
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -f "$log"
  # Das Test-Bündel nicht liegen lassen (Spotlight, App-Übersicht).
  rm -rf build/macos/Build/Products/Debug/*.app
}
trap cleanup EXIT

docker build -q -t paperbuddy:shots ../server >/dev/null
docker run -d --rm --name "$container" -p "127.0.0.1:$port:8000" \
  -e PAPERBUDDY_ADMIN_USER=demo -e PAPERBUDDY_ADMIN_PASSWORD="$password" \
  -e PAPERBUDDY_SCANNER_DISCOVERY=false -e PAPERBUDDY_MAIL_INTERVAL=0 \
  paperbuddy:shots >/dev/null
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/" || true)"
  [ "$code" = 401 ] && break
  sleep 1
done

export FLUTTER_XCODE_PAPERBUDDY_APP_NAME="PaperBuddy Shots"
export FLUTTER_XCODE_PAPERBUDDY_BUNDLE_ID="de.status403.paperbuddy.shots"
mkdir -p ../docs/screenshots
flutter test integration_test/screenshots_test.dart -d macos \
  --dart-define=PAPERBUDDY_SHOTS=1 \
  --dart-define=PAPERBUDDY_SHOTS_SERVER="http://127.0.0.1:$port" \
  --dart-define=PAPERBUDDY_SHOTS_PASSWORD="$password" | tee "$log"
for name in $(grep -o 'SHOT [a-z-]* ' "$log" | cut -d' ' -f2 | sort -u); do
  grep -o "SHOT $name [A-Za-z0-9+/=]*" "$log" | cut -d' ' -f3 | tr -d '\n' \
    | base64 -d >"../docs/screenshots/$name.png"
  echo "docs/screenshots/$name.png"
done
