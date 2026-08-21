#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LEVEL="${1:-patch}"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
IFS='.' read -r major minor patch <<< "$VERSION"
case "$LEVEL" in
  major) ((major++)); minor=0; patch=0 ;;
  minor) ((minor++)); patch=0 ;;
  patch) ((patch++)) ;;
  *) echo "Usage: $0 [major|minor|patch]" >&2; exit 1 ;;
esac
printf '%s.%s.%s\n' "$major" "$minor" "$patch" > "$PROJECT_DIR/VERSION"
echo "$(cat "$PROJECT_DIR/VERSION")"
