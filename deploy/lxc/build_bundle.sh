#!/bin/sh
# Baut das Server-Paket für Linux (Debian/Ubuntu, z. B. ein Proxmox-LXC)
# im Docker-Build-Container und legt es als Tarball ab:
#
#   deploy/lxc/build_bundle.sh [zielordner]          # x64
#   ARCH=arm64 deploy/lxc/build_bundle.sh [zielordner]
#
# Ergebnis: paperbuddy-server-<version>-linux-<arch>.tar.gz mit bin/server,
# bin/manage, lib/ (SQLite) sowie install.sh und paperbuddy.service.
set -eu
cd "$(dirname "$0")/../.."

out="${1:-build/lxc}"
arch="${ARCH:-x64}"
case "$arch" in
  x64) platform=linux/amd64 ;;
  arm64) platform=linux/arm64 ;;
  *) echo "ARCH muss x64 oder arm64 sein" >&2; exit 1 ;;
esac
version="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
version="${version#v}"
name="paperbuddy-server-$version-linux-$arch"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

docker build --platform "$platform" --target build -t "paperbuddy-build:$arch" server
cid="$(docker create --platform "$platform" "paperbuddy-build:$arch")"
docker cp "$cid:/out/server/bundle" "$work/$name"
docker rm "$cid" >/dev/null

cp deploy/lxc/install.sh deploy/lxc/paperbuddy.service "$work/$name/"
echo "$version" > "$work/$name/VERSION"

mkdir -p "$out"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -C "$work" -czf "$out/$name.tar.gz" "$name"
echo "$out/$name.tar.gz"
