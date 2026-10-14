#!/usr/bin/env bash
# Build a release zip with all helpers: .dev/wormhole.koplugin-<version>.zip
# Usage: scripts/release.sh <version>    (e.g. 0.1.0)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version>}"
helper/build.sh
helper/licenses.sh
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/wormhole.koplugin/bin"
cp ./*.lua README.md LICENSE THIRD_PARTY_LICENSES.txt "$STAGE/wormhole.koplugin/"
cp bin/wormhole-helper-armv7 bin/wormhole-helper-arm64 bin/wormhole-helper-x86_64 "$STAGE/wormhole.koplugin/bin/"
chmod +x "$STAGE"/wormhole.koplugin/bin/*
mkdir -p .dev
OUT="$PWD/.dev/wormhole.koplugin-$VERSION.zip"
rm -f "$OUT"
(cd "$STAGE" && nix shell nixpkgs#zip -c zip -qr "$OUT" wormhole.koplugin)
echo "* $OUT ($(du -h "$OUT" | cut -f1))"
nix shell nixpkgs#unzip -c unzip -l "$OUT"
