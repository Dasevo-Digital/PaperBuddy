#!/bin/sh
# Lädt ONNX Runtime und das Modell der lokalen KI für Entwicklung und Tests
# nach .dart_tool/paperbuddy_ai (oder $PAPERBUDDY_AI_CACHE). Die Tests mit
# echtem Modell laufen nur, wenn beides da ist; sonst werden sie übersprungen.
#
#   server/tool/fetch_ai.sh
#
# Danach den Server lokal mit KI starten:
#   PAPERBUDDY_AI=true \
#   PAPERBUDDY_AI_MODELS=.dart_tool/paperbuddy_ai/models \
#   PAPERBUDDY_ONNXRUNTIME=.dart_tool/paperbuddy_ai/onnxruntime/libonnxruntime.dylib \
#   dart run bin/server.dart
set -eu
cd "$(dirname "$0")/.."

cache="${PAPERBUDDY_AI_CACHE:-.dart_tool/paperbuddy_ai}"
version=1.28.3
# Prüfsummen aus der Freigabe auf GitHub (microsoft/onnxruntime, v1.28.3).
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) pkg=osx-arm64; sum=c436bd9f47dbce6f6311ccc21de97f829b3c862c09d24aa321958cb72f0a1d32; lib=libonnxruntime.dylib; src=libonnxruntime.$version.dylib ;;
  Linux-x86_64) pkg=linux-x64; sum=db14e4863bd37893fc59729d986ab2a0d043d10b7d44da1913c4982b7e3d009c; lib=libonnxruntime.so; src=libonnxruntime.so.$version ;;
  Linux-aarch64) pkg=linux-aarch64; sum=6c6b1ae96d7b0be9f555092857c6a4f2b0b5587a5298d732d9e52e8253038ce7; lib=libonnxruntime.so; src=libonnxruntime.so.$version ;;
  *) echo "Keine ONNX Runtime für $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$cache/onnxruntime"
if [ ! -f "$cache/onnxruntime/$lib" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/ort.tgz" \
    "https://github.com/microsoft/onnxruntime/releases/download/v$version/onnxruntime-$pkg-$version.tgz"
  if command -v sha256sum >/dev/null; then
    echo "$sum  $tmp/ort.tgz" | sha256sum -c - >/dev/null
  else
    echo "$sum  $tmp/ort.tgz" | shasum -a 256 -c - >/dev/null
  fi
  tar -xzf "$tmp/ort.tgz" -C "$tmp"
  cp "$tmp/onnxruntime-$pkg-$version/lib/$src" "$cache/onnxruntime/$lib"
fi
echo "ONNX Runtime $version: $cache/onnxruntime/$lib"

dart run bin/manage.dart ai-download "$cache/models"
