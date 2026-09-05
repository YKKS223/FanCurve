#!/bin/bash
# Builds the release binaries and assembles FanCurve.app.
# Run without sudo; install.sh does the privileged part.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Swift ビルド (release)"
swift build -c release

BIN="$ROOT/.build/release"
APP="$ROOT/build/FanCurve.app"

echo "==> アイコンを生成"
mkdir -p "$ROOT/build"
swift "$ROOT/scripts/makeicon.swift" "$ROOT" || echo "(アイコン生成をスキップ)"

echo "==> アプリバンドルを作成"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FanCurveApp" "$APP/Contents/MacOS/FanCurveApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Stamp the build time into the bundle so a stale running copy is obvious in the app itself.
BUILD_STAMP="$(date '+%Y-%m-%d %H:%M')"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_STAMP" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_STAMP" "$APP/Contents/Info.plist"
if [ -f "$ROOT/build/AppIcon.icns" ]; then
    cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature: enough for local use, no Developer ID required.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo
echo "できたもの:"
echo "  $APP"
echo "  $BIN/fancurved     (root デーモン)"
echo "  $BIN/fancurvectl   (CLI)"
echo
echo "次: sudo $ROOT/scripts/install.sh"
