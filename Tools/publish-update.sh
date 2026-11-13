#!/bin/zsh
# Stages a built iPad app + Mac host app as a wireless update. SkyDesk Host (build 17+) notices it within ~5 s,
# offers it to the iPad on its next connection (Update button), and replaces itself after the iPad has it.
# Usage: Tools/publish-update.sh <derived-data-for-pad> <derived-data-for-host>
set -euo pipefail
cd "$(dirname "$0")/.."
PAD="$1/Build/Products/Release-iphoneos/SkyDesk.app"
HOST="$2/Build/Products/Debug/SkyDesk Host.app"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PB=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PAD/Info.plist")
HB=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$HOST/Contents/Info.plist")
[ "$PB" = "$HB" ] || { echo "build numbers differ: iPad $PB, Mac $HB"; exit 1; }
codesign --verify --deep --strict "$HOST"
codesign --verify --strict "$PAD"
DEST="$HOME/Library/Application Support/SkyDesk/Updates"
TMP="$DEST/incoming-$$"
rm -rf "$TMP"; mkdir -p "$TMP/Payload"
ditto "$PAD" "$TMP/Payload/SkyDesk.app"
(cd "$TMP" && /usr/bin/zip -qry SkyDesk.ipa Payload && rm -rf Payload)
ditto "$HOST" "$TMP/SkyDesk Host.app"
$LSR -u "$TMP/SkyDesk Host.app" 2>/dev/null || true
$LSR -u "$HOST" 2>/dev/null || true
print -r -- "{\"build\":$PB}" > "$TMP/info.json"
rm -rf "$DEST/ready.old"
[ -d "$DEST/ready" ] && mv "$DEST/ready" "$DEST/ready.old"
mv "$TMP" "$DEST/ready"
rm -rf "$DEST/ready.old"
$LSR -u "$DEST/ready/SkyDesk Host.app" 2>/dev/null || true
echo "staged build $PB ($(du -sh "$DEST/ready/SkyDesk.ipa" | cut -f1) iPad app) in $DEST/ready"
