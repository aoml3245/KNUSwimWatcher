#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="KNUSwimWatcher"
BUNDLE_ID="com.woni.KNUSwimWatcher"
MIN_SYSTEM_VERSION="14.0"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SWIFT_FLAGS=(--disable-sandbox --scratch-path "$ROOT_DIR/.build" -c "$BUILD_CONFIGURATION")
MODULE_CACHE="$ROOT_DIR/.build/module-cache"

mkdir -p "$MODULE_CACHE"
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build "${SWIFT_FLAGS[@]}" --product "$APP_NAME"
BUILD_BINARY="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>경북대 수영 알림</string>
  <key>CFBundleDisplayName</key>
  <string>경북대 수영 알림</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.21</string>
  <key>CFBundleVersion</key>
  <string>22</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST"
codesign --force --deep --sign - "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME is running"
    ;;
  --notification-test|notification-test)
    /usr/bin/open -n "$APP_BUNDLE" --args --test-notification
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME notification test requested"
    ;;
  --package|package)
    echo "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--notification-test|--package]" >&2
    exit 2
    ;;
esac
