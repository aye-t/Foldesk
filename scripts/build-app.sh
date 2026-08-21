#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/Foldesk.app"
CONTENTS_DIR="$APP_DIR/Contents"
ICONSET_DIR="$PROJECT_DIR/.build/Foldesk.iconset"

cd "$PROJECT_DIR"
swift build -c release

if [[ -d "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
fi

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp ".build/release/Foldesk" "$CONTENTS_DIR/MacOS/Foldesk"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "Sources/Foldesk/Resources/FoldeskIcon.png" "$CONTENTS_DIR/Resources/FoldeskIcon.png"
# 右键「服务」所需的空白模板（主程序内读取，不依赖扩展）
mkdir -p "$CONTENTS_DIR/Resources/Templates"
cp Sources/Foldesk/Resources/Templates/* "$CONTENTS_DIR/Resources/Templates/"

# 选择签名身份：优先用本机受信的自签证书，否则回退 ad-hoc。
LOCAL_CERT="Foldesk Local Dev Code Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$LOCAL_CERT"; then
    SIGN_IDENTITY="$LOCAL_CERT"
else
    SIGN_IDENTITY="-"
fi

# --- Finder Sync 扩展：**不再打包** ---
# Finder Sync 扩展（.appex）必须用 Developer ID 签名并通过公证才能被系统加载，
# 自签 / ad-hoc 环境下 pluginkit 会拒绝注册，嵌进去只会让用户在
# 「系统设置 → 扩展 → 访达」里看到一个永远勾不上的条目。
# 实际生效的右键能力走 NSServices（见 Resources/Info.plist 的 NSServices 数组），
# 由主程序自身提供，不依赖扩展。源码保留在 Sources/FoldeskFinderSync/ 备将来使用。

if [[ -d "$ICONSET_DIR" ]]; then
    rm -rf "$ICONSET_DIR"
fi
mkdir -p "$ICONSET_DIR"
sips -z 16 16 "Sources/Foldesk/Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "Sources/Foldesk/Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "Sources/Foldesk/Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "Sources/Foldesk/Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "Sources/Foldesk/Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "Sources/Foldesk/Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "Sources/Foldesk/Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "Sources/Foldesk/Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "Sources/Foldesk/Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "Sources/Foldesk/Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS_DIR/Resources/FoldeskIcon.icns"

# Keep a stable designated requirement for local development builds. Without
# this, ad-hoc signing defaults to the binary's changing CDHash and macOS treats
# every rebuild as a different app in Accessibility privacy settings.
# 保持固定的 designated requirement，否则每次重新构建都会被
# 「隐私与安全性 → 辅助功能」当成一个新应用，需要反复重新授权。
codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --requirements '=designated => identifier "com.foldesk.mac"' \
    "$APP_DIR"

# 提醒：本脚本产出的是**本机自用**构建。
# 若签名身份回退为 ad-hoc（"-"），该 .app 拷到别人机器上会被 Gatekeeper 拦下。
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "⚠️  使用 ad-hoc 签名：仅供本机使用，分发给他人需 Developer ID + 公证。" >&2
fi

echo "$APP_DIR"
