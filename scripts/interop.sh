#!/usr/bin/env bash
# Compatibility check: our helper against the real `wormhole` command
# (magic-wormhole), both directions, over the public servers (needs internet).
# Exits 1 if any check fails.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v wormhole >/dev/null || { echo "Needs the wormhole command (magic-wormhole)."; exit 1; }
helper/build.sh x86_64 >/dev/null
H="$PWD/bin/wormhole-helper-x86_64"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T"
mkdir -p c save recv Shelf/sub
head -c 3000000 /dev/urandom >Big.epub
echo A >Shelf/a.txt
echo B >Shelf/sub/b.txt
printf "it's ¿bien? \$(no)\nline 2" >text.txt
failed=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failed=1; fi; }

# Start the helper as a sender and wait for its code.
helper_send() {
	: >ev
	"$H" "$@" >ev 2>err &
	HP=$!
	for _ in $(seq 100); do grep -q '"code"' ev && break; sleep 0.1; done
	CODE=$(sed -n 's/.*"code":"\([^"]*\)".*/\1/p' ev)
}

# Our helper sends
helper_send send-text --control c --text-file text.txt
check "text  helper -> wormhole" '[[ "$(timeout 60 wormhole receive --only-text "$CODE" 2>/dev/null)" == "$(cat text.txt)" ]]'
wait $HP

helper_send send-text --control c --text-file text.txt --file-name "text as file.txt"
(cd recv && timeout 90 wormhole receive --accept-file --hide-progress "$CODE" >/dev/null 2>&1)
wait $HP
check "text as a .txt file  helper -> wormhole" 'cmp -s text.txt "recv/text as file.txt"'

helper_send send-file --control c Big.epub
(cd recv && timeout 90 wormhole receive --accept-file --hide-progress "$CODE" >/dev/null 2>&1)
wait $HP
check "file  helper -> wormhole" 'cmp -s Big.epub recv/Big.epub'

helper_send send-files --control c --name Shelf Shelf
(cd recv && timeout 90 wormhole receive --accept-file --hide-progress "$CODE" >/dev/null 2>&1)
wait $HP
check "folder helper -> wormhole" 'diff -r Shelf recv/Shelf >/dev/null'

# The wormhole command sends, our helper receives (and accepts)
helper_receive() {
	CODE="$((RANDOM % 900 + 100))-$(date +%s)-interop"
	rm -f c/answer
	timeout 90 wormhole send --hide-progress --code "$CODE" "$@" >/dev/null 2>&1 &
	WP=$!
	sleep 2
	"$H" receive --control c --code "$CODE" --dir save >ev 2>err &
	HP=$!
	for _ in $(seq 100); do grep -q '"offer"\|"text"' ev && break; sleep 0.1; done
	grep -q '"offer"' ev && { echo accept >c/answer.tmp && mv c/answer.tmp c/answer; }
	wait $HP
	wait $WP
}

helper_receive Big.epub
check "file  wormhole -> helper" 'cmp -s Big.epub save/Big.epub'
helper_receive Shelf
check "folder wormhole -> helper" 'diff -r Shelf save/Shelf >/dev/null'
helper_receive --text "hola ¿qué tal?"
check "text  wormhole -> helper" 'grep -q "\"text\":\"hola ¿qué tal?\"" ev'

# Our helper makes the code (the Kobo shows it as a QR), the wormhole command sends to it
mkdir -p save-new
rm -f c/answer
"$H" receive --control c --new-code --dir save-new >ev 2>err &
HP=$!
for _ in $(seq 100); do grep -q '"code"' ev && break; sleep 0.1; done
CODE=$(sed -n 's/.*"code":"\([^"]*\)".*/\1/p' ev)
check "new code looks like 1234-word-word ($CODE)" '[[ "$CODE" =~ ^[1-9][0-9]{3}-[a-z]+-[a-z]+$ ]]'
timeout 90 wormhole send --hide-progress --code "$CODE" Big.epub >/dev/null 2>&1 &
WP=$!
for _ in $(seq 300); do grep -q '"offer"' ev && break; sleep 0.1; done
echo accept >c/answer.tmp && mv c/answer.tmp c/answer
wait $HP
wait $WP
check "file  wormhole -> helper's own code" 'cmp -s Big.epub save-new/Big.epub'

# Wrong words with a real sender: both sides fail, ours says bad_code
CODE="$((RANDOM % 900 + 100))-$(date +%s)-interop"
timeout 60 wormhole send --text secret --code "$CODE" >/dev/null 2>&1 &
sleep 2
"$H" receive --control c --code "${CODE%%-*}-wrong-words" --dir save >ev 2>err
check "wrong code is bad_code" 'grep -q "\"kind\":\"bad_code\"" ev'
wait

exit $failed
