#!/usr/bin/env bash
# Integrationstests: die echte App gegen einen Wegwerf-Server, für jeden Test
# ein frischer (Zwei-Faktor und Uploads verändern den Server).
#
#   tool/integration_tests.sh <macos|linux> [integration_test/<datei>]…
#
# Ohne Dateien laufen alle Abläufe. Die App läuft als „PaperBuddy E2E“
# (macOS: de.status403.paperbuddy.e2e), Sitzung und Einstellungen bleiben im
# Arbeitsspeicher; installierte Apps und ihre Daten bleiben unberührt.
# Unter Linux braucht es ein Display (CI: xvfb-run).
set -euo pipefail

DEVICE="${1:?Aufruf: tool/integration_tests.sh <macos|linux> [test]…}"
shift
cd "$(dirname "$0")/.."
APP_DIR=$PWD
SERVER_DIR=$APP_DIR/../server

TESTS=("$@")
if [ ${#TESTS[@]} -eq 0 ]; then
  TESTS=(
    integration_test/login_flow_test.dart
    integration_test/documents_flow_test.dart
  )
fi

if [ "$DEVICE" = macos ]; then
  export FLUTTER_XCODE_PAPERBUDDY_APP_NAME="PaperBuddy E2E"
  export FLUTTER_XCODE_PAPERBUDDY_BUNDLE_ID=de.status403.paperbuddy.e2e
fi

WORK=$(mktemp -d)
SERVER_PID=
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
  # Gebaute Bündel tauchten sonst in Spotlight und der App-Übersicht auf.
  if [ "$DEVICE" = macos ]; then
    find "$APP_DIR/build/macos" -name '*.app' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  fi
}
trap cleanup EXIT

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}

echo "== Server bauen"
(cd "$SERVER_DIR" && dart pub get >/dev/null && dart build cli -t bin/server.dart -o "$WORK/server" >/dev/null)
SERVER_BIN=$(find "$WORK/server" -type f -name server -perm -u+x | head -1)
[ -x "$SERVER_BIN" ] || { echo "Server-Binary nicht gefunden" >&2; exit 1; }

PASSWORD="e2e-$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
failed=()

for test in "${TESTS[@]}"; do
  echo "== $test"
  data=$(mktemp -d "$WORK/data.XXXXXX")
  port=$(free_port)
  log=$data.log
  PAPERBUDDY_DATA_DIR=$data PAPERBUDDY_PORT=$port PAPERBUDDY_BIND_ADDR=127.0.0.1 \
    PAPERBUDDY_ADMIN_USER=admin PAPERBUDDY_ADMIN_PASSWORD="$PASSWORD" \
    PAPERBUDDY_SCANNER_DISCOVERY=false PAPERBUDDY_MAIL_INTERVAL=0 \
    "$SERVER_BIN" >"$log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 60); do
    curl -fs "http://127.0.0.1:$port/api/health/" >/dev/null && break
    sleep 0.5
  done

  if flutter test "$test" -d "$DEVICE" \
    --dart-define=PAPERBUDDY_E2E_SERVER="http://127.0.0.1:$port" \
    --dart-define=PAPERBUDDY_E2E_USER=admin \
    --dart-define=PAPERBUDDY_E2E_PASSWORD="$PASSWORD"; then
    echo "== OK: $test"
  else
    echo "== FEHLER: $test" >&2
    tail -40 "$log" >&2
    failed+=("$test")
  fi
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "Fehlgeschlagen: ${failed[*]}" >&2
  exit 1
fi
echo "Alle ${#TESTS[@]} Integrationstests bestanden."
