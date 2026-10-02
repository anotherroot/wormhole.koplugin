#!/usr/bin/env bash
# All tests: Go helper (go vet + go test), then Lua (luacheck + busted, with
# KOReader's own json module from the extracted AppImage).
# Extra arguments go to busted, e.g. scripts/test.sh spec/wh_session_spec.lua
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/setup-dev.sh
(cd helper && go vet ./... && go test ./...)
export KOREADER_DIR="$PWD/.dev/squashfs-root/usr/lib/koreader"
exec nix shell nixpkgs#luajitPackages.busted nixpkgs#luajitPackages.luacheck \
	-c sh -c 'luacheck -q . && busted "$@"' sh "$@"
