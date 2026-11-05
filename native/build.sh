#!/bin/bash
# 构建「牛马鼓励器.app」—— 不依赖 Xcode，只需 Command Line Tools（clang）
# 产物是 arm64 + x86_64 通用二进制，ad-hoc 签名，可直接在本机双击运行。
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/dist/牛马鼓励器.app"
BIN="$APP/Contents/MacOS/NiuMaWidget"

echo "▸ 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 编译原生壳（arm64 + x86_64）"
clang -fobjc-arc -O2 -Wall -mmacosx-version-min=12.0 \
      -arch arm64 -arch x86_64 \
      -o "$BIN" native/main.m -framework Cocoa -framework WebKit

echo "▸ 打包资源"
cp native/Info.plist "$APP/Contents/Info.plist"
rm -rf "$APP/Contents/Resources/app"
cp -R app "$APP/Contents/Resources/app"

echo "▸ ad-hoc 签名"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (跳过签名，本机仍可运行)"

SIZE=$(du -sh "$APP" | cut -f1)
ARCHS=$(lipo -archs "$BIN" 2>/dev/null || echo "?")
echo "▸ 完成 → $APP  ($SIZE, $ARCHS)"
echo "  open \"$APP\"  # 首次打开被拦时：右键 → 打开"
