#!/usr/bin/env bash
# Screen tour: runs the laptop KOReader headless with dev/tour.koplugin, which
# drives real transfers against the `wormhole` command (public server, needs
# internet) and screenshots every screen into .dev/tour/.
# Prints the PASS/FAIL log; exits 1 if anything failed.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/setup-dev.sh
command -v wormhole >/dev/null || { echo "Needs the wormhole command (magic-wormhole)."; exit 1; }

OUT="$PWD/.dev/tour"
rm -rf "$OUT"
mkdir -p "$OUT"
ln -sfn "$PWD/dev/tour.koplugin" .dev/home/plugins/tour.koplugin
trap 'rm -f .dev/home/plugins/tour.koplugin' EXIT

# XDG_DOCUMENTS_DIR is the laptop KOReader's "device home": received files go
# to $OUT/Wormhole, never to the real home folder.
SDL_VIDEODRIVER=offscreen KO_HOME="$PWD/.dev/home" XDG_DOCUMENTS_DIR="$OUT" \
	WH_TOUR_OUT="$OUT" WH_BOOK="$PWD/.dev/books/alice.epub" WH_PLUGIN_DIR="$PWD" \
	WH_CLI="$(command -v wormhole)" \
	timeout 300 nix run nixpkgs#appimage-run -- ".dev/koreader-v2026.03.AppImage" "$OUT" \
	>"$OUT/koreader.log" 2>&1 || true

# The QR on the send screen must decode to the code's link.
code=$(sed -n 's/^PASS send shows a code: //p' "$OUT/log.txt")
qr=$(nix shell nixpkgs#zbar -c zbarimg -q --raw "$OUT/01-send-code.png" 2>/dev/null || true)
if [[ -n "$code" && "$qr" == "wormhole-transfer:$code" ]]; then
	echo "PASS QR on the send screen decodes to $qr" >>"$OUT/log.txt"
else
	echo "FAIL QR on the send screen decodes to '$qr', want wormhole-transfer:$code" >>"$OUT/log.txt"
fi

# The QR for receiving asks the scanner to send: role=leader.
code=$(sed -n 's/^PASS receive shows a code: //p' "$OUT/log.txt")
qr=$(nix shell nixpkgs#zbar -c zbarimg -q --raw "$OUT/04b-receive-qr.png" 2>/dev/null || true)
if [[ -n "$code" && "$qr" == "wormhole-transfer:$code?role=leader" ]]; then
	echo "PASS QR for receiving decodes to $qr" >>"$OUT/log.txt"
else
	echo "FAIL QR for receiving decodes to '$qr', want wormhole-transfer:$code?role=leader" >>"$OUT/log.txt"
fi

cat "$OUT/log.txt"
echo "Screenshots: $OUT/*.png"
grep -q '^END' "$OUT/log.txt" || { echo "Tour did not finish (see $OUT/koreader.log)"; exit 1; }
! grep -q '^FAIL' "$OUT/log.txt"
