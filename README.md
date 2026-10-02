# Wormhole for KOReader

Send and receive text, books, files and folders between your e-reader and
any other device with [Magic Wormhole](https://magic-wormhole.readthedocs.io/).
One side gets a short code like `7-guitarist-revenge`, the other side types
it, and the data goes across, end-to-end encrypted, over any network: no
accounts, no cables, and the devices don't need to share a Wi-Fi.

Status: experimental. Tested on a Kobo Colour with KOReader v2026.03.

## What you can do

| Where in KOReader | What it sends |
|---|---|
| Select text → **Send via wormhole** | the selected text |
| Tap an existing highlight → **…** → **Send via wormhole** | the highlight and its note |
| Menu → Tools → Wormhole → **Send current book** | the open book |
| File browser: long-press a file or folder → **Send via wormhole** | that file, or the whole folder |
| File browser select mode, then Menu → Tools → Wormhole → **Send selected files (N)** | the ticked files, as one folder |
| Menu → Tools → Wormhole → **Receive…** | type a code to receive text, a file or a folder |

Text can go as a text message or as a small `.txt` file named after its first
words. Wormhole → Settings → **When sending text**: Ask each time (default),
Always as text, or Always as a file. Use a file for apps that can't receive
text messages: Warp and the Android Wormhole app (built on magic-wormhole.rs).

**On the other side** use any Magic Wormhole app:
- a computer: the `wormhole` command (`pip install magic-wormhole`, or your
  package manager), then `wormhole receive` or `wormhole send <file>`
- Linux desktop: Warp
- Android and iOS: Destiny

**Received** files and folders go to `Wormhole/` in the device's main storage
(`/mnt/onboard/Wormhole` on a Kobo); change it in Wormhole → Settings. A file
with the same name is never overwritten: the new one becomes `Book (2).epub`.
Before a file or folder downloads you see its name and size and can reject it.
Received text opens in a popup with a **Copy** button.

## Install

1. Download the release zip and unpack `wormhole.koplugin` into KOReader's
   `plugins/` folder (on a Kobo: `.adds/koreader/plugins/`).
2. Restart KOReader.

The zip contains helper programs for `armv7` (Kobo, most Kindles and
PocketBooks), `arm64` (newer devices such as the reMarkable Paper Pro) and
`x86_64` (KOReader on a Linux computer). They need Linux 3.2 or newer, so very
old Kindles can't run them.

## Good to know

- Both devices need internet. The code is only valid once: after a wrong
  try, both sides stop and the sender sends again for a new code.
- The plugin keeps the device awake while a transfer screen is open. Pressing
  the power button stops the transfer.
- A mistyped code *number* makes the receiver wait for a sender that never
  comes. Press Cancel and check the code.
- By default the free public Magic Wormhole servers are used (the same ones
  every Wormhole app uses). Your own servers can be set in Settings.

## How it works

`wormhole-helper` is a small Go program built on
[wormhole-william](https://github.com/psanford/wormhole-william). It does the
networking and encryption and writes one JSON line per event. The Lua plugin
starts it in the background, reads those lines a few times a second, and draws
the screens. Cancel stops the helper.

| File | Job |
|---|---|
| `main.lua`, `_meta.lua` | menu items and buttons |
| `wh_run.lua` | runs one transfer: Wi-Fi, helper, poll loop, dialog, keeping the device awake |
| `wh_helper.lua` | starts the helper, reads its events, answers and cancels |
| `wh_session.lua` | one transfer's state, driven by events |
| `wh_ui.lua` | the transfer dialog, the code box, the received-text popup |
| `wh_format.lua` | code clean-up, sizes, messages |
| `wh_files.lua` | settings and folders |
| `wh_safe.lua` | crash guards for every callback KOReader calls |
| `helper/` | the Go helper and `build.sh` |

## Development

Needs Nix (for luajit, busted, luacheck and appimage-run), Go, and the
`wormhole` command for the checks that talk to real servers.

- `scripts/test.sh`: Go tests (offline, with an in-process server), then
  luacheck and busted. Downloads KOReader v2026.03 into `.dev/` the first time.
- `scripts/interop.sh`: our helper against the `wormhole` command, both
  directions (needs internet).
- `scripts/tour.sh`: runs KOReader headless with `dev/tour.koplugin`, which
  drives real transfers through every screen, prints PASS/FAIL and saves
  screenshots to `.dev/tour/` (needs internet).
- `scripts/dev-run.sh [book or folder]`: KOReader on the computer with the
  plugin, its own settings in `.dev/home`, received files in `.dev/Wormhole`.
- `helper/build.sh [armv7|arm64|x86_64]`: build helpers into `bin/`.
- `scripts/install-kobo.sh`: copy onto a mounted Kobo (the owner's setup).
- `scripts/release.sh <version>`: release zip with all three helpers in `.dev/`.

## Later

QR code for the code, code-word completion while typing, background
transfers, saving received text, resuming a broken transfer.

Before publishing a release zip: add the third-party license notices of the
Go modules compiled into the helpers (wormhole-william MIT, golang.org/x/crypto
BSD, …), e.g. with `go-licenses save`.

## License

MIT. wormhole-william is MIT too.
