#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/build/拾词助手.app"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/拾词助手.app"

# LaunchServices activates an already-running menu-bar app instead of replacing
# it, so explicitly close the old process before replacing its bundle.
osascript -e 'tell application id "com.coty.vocab-capture" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -f "$TARGET_APP/Contents/MacOS/VocabCapture" >/dev/null || break
  sleep 0.1
done

"$PROJECT_DIR/scripts/package-app.sh"
mkdir -p "$TARGET_DIR"
if [[ -e "$TARGET_APP" ]]; then
  BACKUP="$HOME/.Trash/拾词助手-$(date +%Y%m%d-%H%M%S).app"
  mv "$TARGET_APP" "$BACKUP"
fi
ditto "$SOURCE_APP" "$TARGET_APP"
# `ditto` may preserve Finder metadata from a previously launched bundle.
xattr -cr "$TARGET_APP" 2>/dev/null || true
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$SOURCE_APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$TARGET_APP" >/dev/null 2>&1 || true
fi
# The generated bundle must not remain as a second discoverable app outside
# ~/Applications, otherwise Launchpad may show historical duplicates.
rm -rf "$SOURCE_APP"
open "$TARGET_APP"
echo "$TARGET_APP"
