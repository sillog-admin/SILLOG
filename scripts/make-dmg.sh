#!/bin/bash
# Packs SILLOG.app into a dmg that opens on a window showing the app, an arrow and Applications to drag it onto.
#   scripts/make-dmg.sh <SILLOG.app> <out.dmg>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$1"
OUT="$2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift "$ROOT/scripts/dmg/background.swift" "$ROOT/Sources/SillogApp/Resources/Brand/Fonts" "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null

# dmgbuild writes the window layout (.DS_Store) itself, so it needs no Finder or screen on CI. Pinned with its dependencies.
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet --disable-pip-version-check dmgbuild==1.6.7 ds_store==1.3.3 mac_alias==2.2.3
rm -f "$OUT"
"$WORK/venv/bin/dmgbuild" -s "$ROOT/scripts/dmg/settings.py" -D app="$APP" -D background="$WORK/background.tiff" SILLOG "$OUT"
