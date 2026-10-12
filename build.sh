#!/bin/bash
# Builds Ticker Flow.app, installs it in ~/Applications and opens it.
# Usage:  ./build.sh            build + install + open
#         ./build.sh --no-open  build + install only
set -euo pipefail
cd "$(dirname "$0")"
exec > >(tee build.log) 2>&1

APP_NAME="Ticker Flow"
BUILD_APP="build/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
ARCH="$(uname -m)"

echo "==> Building $APP_NAME for $ARCH"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "error: The Swift compiler wasn't found. Install Xcode, or run: xcode-select --install"
  exit 1
fi
xcrun swiftc --version | head -1

rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources"

xcrun --sdk macosx swiftc -O -parse-as-library \
  -target "$ARCH-apple-macos12.0" \
  -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers \
  Sources/TickerFlow.swift \
  -o "$BUILD_APP/Contents/MacOS/TickerFlow"

cp Resources/Info.plist "$BUILD_APP/Contents/Info.plist"
cp Resources/index.html "$BUILD_APP/Contents/Resources/index.html"
cp Resources/AppIcon.icns "$BUILD_APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUILD_APP/Contents/PkgInfo"

echo "==> Signing (ad hoc, for this Mac)"
codesign --force --deep --sign - "$BUILD_APP"

echo "==> Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
rm -rf "$INSTALL_DIR/$APP_NAME.app"
ditto "$BUILD_APP" "$INSTALL_DIR/$APP_NAME.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1 || true

echo "==> Done: $INSTALL_DIR/$APP_NAME.app"
if [ "${1:-}" != "--no-open" ]; then
  open "$INSTALL_DIR/$APP_NAME.app"
fi
