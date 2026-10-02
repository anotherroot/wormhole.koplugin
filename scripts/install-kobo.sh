#!/usr/bin/env bash
# Copy the plugin (runtime files + the armv7 helper) onto a mounted Kobo.
# Mount first with ~/Projects/kobo/scripts/kobo-mount.sh. Backs up KOReader
# settings first and never touches .adds/koreader/settings*.
set -euo pipefail
cd "$(dirname "$0")/.."
KOBO="${1:-/run/media/$USER/KOBOeReader}"
DEST="$KOBO/.adds/koreader/plugins/wormhole.koplugin"

if [[ ! -d "$KOBO/.adds/koreader/plugins" ]]; then
	echo "No KOReader found at $KOBO. Mount the Kobo first (~/Projects/kobo/scripts/kobo-mount.sh)."
	exit 1
fi

helper/build.sh armv7
"$HOME/Projects/kobo/scripts/backup-koreader.sh" "$KOBO"

mkdir -p "$DEST/bin"
rsync -rt --delete --include='*.lua' --include='bin/' --include='bin/wormhole-helper-armv7' --exclude='*' ./ "$DEST/"
chmod +x "$DEST/bin/wormhole-helper-armv7" 2>/dev/null || true # no-op on the Kobo's FAT, needed elsewhere
sync

echo "* Checking the copy"
for f in *.lua bin/wormhole-helper-armv7; do
	cmp "$f" "$DEST/$f"
done
echo "* Installed to $DEST:"
ls -R "$DEST"
echo "  Now eject (~/Projects/kobo/scripts/kobo-mount.sh eject) and restart KOReader on the Kobo."
