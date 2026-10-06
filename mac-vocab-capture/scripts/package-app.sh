#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="拾词助手"
APP_DIR="$PROJECT_DIR/build/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
SIGNING_IDENTITY="${VOCAB_CAPTURE_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
fi

cd "$PROJECT_DIR"
swift build -c release
"$PROJECT_DIR/scripts/build-question-engine.sh"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Helpers"
ditto --norsrc "$PROJECT_DIR/build/langchain/dist/QuestionEngine" "$CONTENTS/Helpers/QuestionEngine"
cp .build/release/VocabCapture "$CONTENTS/MacOS/VocabCapture"
cp Resources/Info.plist "$CONTENTS/Info.plist"
"$PROJECT_DIR/scripts/build-app-icon.sh"
cp "$PROJECT_DIR/build/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$CONTENTS/Info.plist"
chmod 755 "$CONTENTS/MacOS/VocabCapture"
# Finder metadata can invalidate an otherwise valid code signature.
xattr -cr "$APP_DIR" 2>/dev/null || true
if [[ -n "$SIGNING_IDENTITY" ]]; then
  "$PROJECT_DIR/question-engine/.venv/bin/python" "$PROJECT_DIR/scripts/sign-app.py" \
    "$APP_DIR" "$SIGNING_IDENTITY"
else
  # A stable Apple Development identity can be supplied through
  # VOCAB_CAPTURE_SIGNING_IDENTITY. Until then, keep a single fixed install
  # location and avoid opening build artifacts, which minimizes TCC churn.
  "$PROJECT_DIR/question-engine/.venv/bin/python" "$PROJECT_DIR/scripts/sign-app.py" \
    "$APP_DIR" -
fi
echo "$APP_DIR"
