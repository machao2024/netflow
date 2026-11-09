#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
RUN=false
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --run) RUN=true ;;
        *) echo "用法：./build.sh [--debug] [--run]"; exit 1 ;;
    esac
done
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --configuration "$CONFIG" --arch arm64 --scratch-path .build --cache-path .build/cache
BIN_DIR="$(swift build --disable-sandbox --configuration "$CONFIG" --arch arm64 --scratch-path .build --cache-path .build/cache --show-bin-path)"
APP_DIR="$PWD/dist/NetFlow.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/NetFlow" "$APP_DIR/Contents/MacOS/NetFlow"
if [ ! -f .build/AppIcon.icns ] || [ scripts/make_icon.swift -nt .build/AppIcon.icns ]; then
    swift scripts/make_icon.swift "$PWD/.build/NetFlow.iconset"
    iconutil -c icns .build/NetFlow.iconset -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>NetFlow</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.netflow.monitor</string>
    <key>CFBundleName</key><string>NetFlow</string>
    <key>CFBundleDisplayName</key><string>NetFlow</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$PWD/dist/NetFlow-1.0.0-arm64.zip"
echo "已生成：$APP_DIR"
if [ "$RUN" = true ]; then open "$APP_DIR"; fi
