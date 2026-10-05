#!/bin/sh
# Baut das Server-Paket für Linux x64 (Debian/Ubuntu, z. B. ein Proxmox-LXC)
# im Docker-Build-Container und legt es als Tarball ab:
#
#   deploy/lxc/build_bundle.sh [zielordner]
#
# Ergebnis: paperbuddy-server-<version>-linux-x64.tar.gz mit bin/server,
# bin/manage, lib/ (SQLite) sowie install.sh und paperbuddy.service.
set -eu
cd "$(dirname "$0")/../.."

out="${1:-build/lxc}"
version="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
name="paperbuddy-server-$version-linux-x64"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

docker build --platform linux/amd64 --target build -t paperbuddy-build:lxc server
cid="$(docker create --platform linux/amd64 paperbuddy-build:lxc)"
docker cp "$cid:/out/server/bundle" "$work/$name"
docker rm "$cid" >/dev/null

cp deploy/lxc/install.sh deploy/lxc/paperbuddy.service "$work/$name/"
echo "$version" > "$work/$name/VERSION"

mkdir -p "$out"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -C "$work" -czf "$out/$name.tar.gz" "$name"
echo "$out/$name.tar.gz"
