#!/usr/bin/env bash
set -euo pipefail

APP_NAME="KNUSwimWatcher"
INSTALL_APP="$HOME/Applications/KNUSwimWatcher.app"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
if [[ -d "$INSTALL_APP" ]]; then
  mv "$INSTALL_APP" "$HOME/.Trash/KNUSwimWatcher.app.$(date +%Y%m%d-%H%M%S)"
  echo "앱을 휴지통으로 이동했습니다."
else
  echo "설치된 앱이 없습니다."
fi

echo "Keychain 비밀번호와 앱 설정은 실수 방지를 위해 보존했습니다."
