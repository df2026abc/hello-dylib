#!/bin/bash
# language: bash, file: cs2pos_src/build.sh, host: macOS + Xcode command line tools
# 编译 CS2手游Pos1.0绘制自瞄版 dylib — arm64, iOS 15.0+
set -euo pipefail

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT="${OUT:-twin.dylib}"

echo "SDK: $SDK"
echo "输出: $OUT"

clang++ -arch arm64 \
  -miphoneos-version-min=15.0 \
  -isysroot "$SDK" \
  -std=c++17 -O2 -fobjc-arc \
  -framework UIKit \
  -framework Foundation \
  -framework QuartzCore \
  -framework CoreGraphics \
  -framework Security \
  -dynamiclib \
  -install_name @executable_path/Frameworks/twin.dylib \
  -Wl,-undefined,dynamic_lookup \
  -o "$OUT" \
  il2cpp_kit.mm \
  twin_esp.mm \
  twin_aim.mm \
  twin_backup.mm \
  twin_unban.mm \
  twin_shield.mm \
  twin_ui.mm \
  bypass.mm \
  twin_probe.mm

echo ""
echo "编译完成: $OUT"
lipo -info "$OUT"
ls -lh "$OUT"
