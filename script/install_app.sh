#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/KNUSwimWatcher.app"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/KNUSwimWatcher.app"

BUILD_CONFIGURATION=release "$ROOT_DIR/script/build_and_run.sh" --package

mkdir -p "$INSTALL_DIR"
if [[ -d "$INSTALL_APP" ]]; then
  mv "$INSTALL_APP" "$HOME/.Trash/KNUSwimWatcher.app.$(date +%Y%m%d-%H%M%S)"
fi
cp -R "$SOURCE_APP" "$INSTALL_APP"
codesign --verify --deep --strict "$INSTALL_APP"
/usr/bin/open -n "$INSTALL_APP"

echo "설치 완료: $INSTALL_APP"
