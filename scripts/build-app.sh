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

# --- Finder Sync 扩展（.appex） ---
APPEX_DIR="$CONTENTS_DIR/PlugIns/FoldeskFinderSync.appex"
rm -rf "$APPEX_DIR"
mkdir -p "$APPEX_DIR/Contents/MacOS" "$APPEX_DIR/Contents/Resources/Templates"
cp ".build/release/FoldeskFinderSync" "$APPEX_DIR/Contents/MacOS/FoldeskFinderSync"
cp "Sources/FoldeskFinderSync/Info.plist" "$APPEX_DIR/Contents/Info.plist"
cp Sources/FoldeskFinderSync/Resources/Templates/* "$APPEX_DIR/Contents/Resources/Templates/"
# 先单独签名扩展（其 identifier 为 com.foldesk.mac.FinderSync，需自有签名）
codesign --force --sign "$SIGN_IDENTITY" "$APPEX_DIR"

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
# 注意：不要使用 --deep。--deep 会把上方仅针对主 app 的 designated requirement
# 强加给嵌套的 Finder Sync 扩展（其 identifier 为 com.foldesk.mac.FinderSync），
# 导致扩展“does not satisfy its designated Requirement”、嵌套校验失败、扩展无法加载。
# 正确做法：扩展已单独签名，这里只签主 app 自身并封存整个 bundle。
codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --requirements '=designated => identifier "com.foldesk.mac"' \
    "$APP_DIR"

echo "$APP_DIR"
