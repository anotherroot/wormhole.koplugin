#!/usr/bin/env bash
# Build the helper into ../bin/. No arguments: every processor we ship.
# Or name some: helper/build.sh x86_64   (armv7 | arm64 | x86_64)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../bin
archs=("$@")
[[ ${#archs[@]} -gt 0 ]] || archs=(armv7 arm64 x86_64)
for arch in "${archs[@]}"; do
	case "$arch" in
	armv7) env=(GOARCH=arm GOARM=7) ;;
	arm64) env=(GOARCH=arm64) ;;
	x86_64) env=(GOARCH=amd64) ;;
	*) echo "unknown processor: $arch" >&2; exit 1 ;;
	esac
	echo "* Building wormhole-helper-$arch"
	env CGO_ENABLED=0 GOOS=linux "${env[@]}" go build -trimpath -ldflags="-s -w" -o "../bin/wormhole-helper-$arch" .
done
