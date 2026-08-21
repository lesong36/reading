#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="拾词助手"
APP_DIR="$PROJECT_DIR/build/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
SIGNING_IDENTITY="${VOCAB_CAPTURE_SIGNING_IDENTITY:-}"

cd "$PROJECT_DIR"
swift build -c release
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/VocabCapture "$CONTENTS/MacOS/VocabCapture"
cp Resources/Info.plist "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$CONTENTS/Info.plist"
chmod 755 "$CONTENTS/MacOS/VocabCapture"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR" >/dev/null
else
  # A stable Apple Development identity can be supplied through
  # VOCAB_CAPTURE_SIGNING_IDENTITY. Until then, keep a single fixed install
  # location and avoid opening build artifacts, which minimizes TCC churn.
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi
echo "$APP_DIR"
