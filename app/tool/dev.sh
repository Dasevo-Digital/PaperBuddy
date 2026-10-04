#!/bin/sh
# Startet die Entwicklungsvariante "PaperBuddy Dev" neben der normalen App:
# eigene Bundle-ID (de.status403.paperbuddy.dev), eigener Name, eigener
# Schlüsselbund-Eintrag. So fassen Probe-Builds nie die echte App oder
# deren Anmeldung an.
#
#   tool/dev.sh macos            flutter run auf diesem Mac
#   tool/dev.sh ios [gerät]      flutter run auf iPhone/Simulator
#   tool/dev.sh android [gerät]  flutter run --flavor dev
#   tool/dev.sh web              flutter run -d chrome
#
# Weitere Argumente gehen an flutter run.
set -eu
cd "$(dirname "$0")/.."

target="${1:-macos}"
[ $# -gt 0 ] && shift

define="--dart-define=PAPERBUDDY_ENV=dev"

# Build-Produkte aus Spotlight heraushalten (Ordner *.noindex werden nicht
# indiziert), damit dort nur installierte Apps auftauchen.
if [ -d build ] && [ ! -L build ]; then
  rm -rf build.noindex
  mv build build.noindex
fi
mkdir -p build.noindex
[ -L build ] || ln -s build.noindex build

case "$target" in
  macos|ios)
    export FLUTTER_XCODE_PAPERBUDDY_APP_NAME="PaperBuddy Dev"
    export FLUTTER_XCODE_PAPERBUDDY_BUNDLE_ID="de.status403.paperbuddy.dev"
    if [ "$target" = macos ]; then
      exec flutter run -d macos "$define" "$@"
    fi
    if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then device="$1"; shift; exec flutter run -d "$device" "$define" "$@"; fi
    exec flutter run -d ios "$define" "$@"
    ;;
  android)
    if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then device="$1"; shift; exec flutter run -d "$device" --flavor dev "$define" "$@"; fi
    exec flutter run --flavor dev "$define" "$@"
    ;;
  web)
    exec flutter run -d chrome "$define" "$@"
    ;;
  *)
    echo "Unbekanntes Ziel: $target (macos, ios, android, web)" >&2
    exit 1
    ;;
esac
