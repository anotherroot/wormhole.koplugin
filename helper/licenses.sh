#!/usr/bin/env bash
# Write ../THIRD_PARTY_LICENSES.txt: the license of every Go module compiled
# into the helpers (all processors we ship), plus Go's own standard library.
set -euo pipefail
cd "$(dirname "$0")"
OUT=../THIRD_PARTY_LICENSES.txt
go mod download
mods=$(for arch in arm arm64 amd64; do
	GOOS=linux GOARCH=$arch go list -deps \
		-f '{{if and (not .Standard) .Module (not .Module.Main)}}{{.Module.Path}}@{{.Module.Version}}{{end}}' .
done | sort -u)
{
	echo "wormhole-helper (bin/wormhole-helper-*) is built from these Go modules."
	echo "Their licenses follow."
	for mod in $mods; do
		dir=$(go list -m -f '{{.Dir}}' "${mod%@*}")
		files=$(find "$dir" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname 'PATENTS*' \) | sort)
		[[ -n $files ]] || { echo "no license file in $mod" >&2; exit 1; }
		for f in $files; do
			printf '\n%s\n%s (%s)\n%s\n\n' "$(printf '=%.0s' {1..72})" "$mod" "$(basename "$f")" "$(printf '=%.0s' {1..72})"
			cat "$f"
		done
	done
	# Nix's Go has no LICENSE file; the standard library's is the same text
	# as golang.org/x/crypto's (Copyright 2009 The Go Authors, BSD-3-Clause).
	crypto=$(go list -m -f '{{.Dir}}' golang.org/x/crypto)
	printf '\n%s\n%s (LICENSE)\n%s\n\n' "$(printf '=%.0s' {1..72})" "Go standard library and runtime, $(go env GOVERSION)" "$(printf '=%.0s' {1..72})"
	cat "$crypto/LICENSE"
} >"$OUT"
echo "* $(realpath "$OUT"): $(wc -w <<<"$mods") modules + Go"
