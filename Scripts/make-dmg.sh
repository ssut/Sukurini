#!/bin/bash
set -euo pipefail

APP_PATH="${1:?usage: make-dmg.sh <app-path> <output-dmg> [volume-name]}"
OUTPUT="${2:?usage: make-dmg.sh <app-path> <output-dmg> [volume-name]}"
VOLNAME="${3:-$(basename "$APP_PATH" .app)}"
APP_NAME="$(basename "$APP_PATH")"

WINDOW_WIDTH=600
WINDOW_HEIGHT=400
ICON_SIZE=128
APP_ICON_X=150
APP_ICON_Y=190
LINK_ICON_X=450
LINK_ICON_Y=190

if [ ! -d "$APP_PATH" ]; then
  echo "dmg status=fail reason=app_missing path=$APP_PATH" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
RW_DMG="$(mktemp -u).dmg"
MOUNT_POINT=""

cleanup() {
  if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet -force 2>/dev/null || true
  fi
  rm -rf "$STAGING" "$RW_DMG" 2>/dev/null || true
}
trap cleanup EXIT

ditto "$APP_PATH" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"
echo "dmg staging prepared app=$APP_NAME bytes=$(du -sk "$STAGING" | awk '{print $1 * 1024}')"

hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDRW -fs HFS+ "$RW_DMG" -quiet
echo "dmg writable image created"

MOUNT_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -nobrowse)"
MOUNT_POINT="$(printf '%s' "$MOUNT_OUTPUT" | grep -Eo '/Volumes/.*$' | head -1)"
if [ -z "$MOUNT_POINT" ]; then
  echo "dmg status=fail reason=mount_failed" >&2
  exit 1
fi
echo "dmg mounted at=$MOUNT_POINT"

STYLED=false
if osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, $((200 + WINDOW_WIDTH)), $((120 + WINDOW_HEIGHT))}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to $ICON_SIZE
        set position of item "$APP_NAME" of container window to {$APP_ICON_X, $APP_ICON_Y}
        set position of item "Applications" of container window to {$LINK_ICON_X, $LINK_ICON_Y}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
  STYLED=true
  echo "dmg window styled icons=${ICON_SIZE} size=${WINDOW_WIDTH}x${WINDOW_HEIGHT}"
else
  echo "dmg window styling skipped reason=finder_unavailable drag_target=intact"
fi

sync
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

rm -f "$OUTPUT"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT" -quiet
echo "dmg status=ok path=$OUTPUT bytes=$(wc -c < "$OUTPUT") styled=$STYLED volume=$VOLNAME"
