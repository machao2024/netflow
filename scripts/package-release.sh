#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_DIR="$PWD/dist/NetFlow.app"
if [ ! -d "$APP_DIR" ]; then
    echo "请先运行 ./build.sh 生成 dist/NetFlow.app"
    exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "版本号格式不正确：$VERSION"
    exit 1
fi
if [ "$(lipo -archs "$APP_DIR/Contents/MacOS/NetFlow")" != arm64 ]; then
    echo "发布包需要 arm64 架构的 NetFlow"
    exit 1
fi
codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist"

mkdir -p .build dist
STAGING="$(mktemp -d "$PWD/.build/release-staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP_DIR" "$STAGING/NetFlow.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/安装说明.txt" <<'NOTES'
NetFlow · Mac 网络监控

系统要求：Apple Silicon（M1/M2/M3/M4 等），macOS 13 或更高版本。

1. 将 NetFlow.app 拖到旁边的 Applications 文件夹。
2. 从「应用程序」打开 NetFlow。它会显示在菜单栏，没有 Dock 图标。
3. 点击菜单栏查看实时上下行和最近记录，可切换分钟、小时或天。

发布包使用本地 ad-hoc 签名，未经过 Apple Developer ID 公证。
首次打开如被 macOS 拦截，可在「系统设置 → 隐私与安全性」中找到
NetFlow 并选择「仍要打开」。

更新已有版本前请先退出正在运行的 NetFlow，再替换应用。
历史记录保存在 ~/Library/Application Support/NetFlow，不随应用替换而删除。

源码与反馈：https://github.com/machao2024/netflow
NOTES

ZIP_NAME="NetFlow-$VERSION-arm64.zip"
DMG_NAME="NetFlow-$VERSION-arm64.dmg"
ditto -c -k --sequesterRsrc --keepParent "$STAGING/NetFlow.app" "$PWD/dist/$ZIP_NAME"
hdiutil create -ov -volname "NetFlow $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -quiet "$PWD/dist/$DMG_NAME"
hdiutil verify "$PWD/dist/$DMG_NAME"
(
    cd dist
    shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt
)
echo "已生成 dist/${DMG_NAME}、dist/${ZIP_NAME} 和 dist/SHA256SUMS.txt"
