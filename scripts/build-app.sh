#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/Foldesk.app"
CONTENTS_DIR="$APP_DIR/Contents"
ICONSET_DIR="$PROJECT_DIR/.build/Foldesk.iconset"
PLUGINS_DIR="$CONTENTS_DIR/PlugIns"
EXTENSION_DIR="$PLUGINS_DIR/FoldeskFinderSync.appex"

cd "$PROJECT_DIR"

# SwiftPM 默认会用 sandbox-exec 编译 manifest。在禁止 sandbox_apply 的受限环境
# （部分 CI / 容器 / 沙箱）里这一步会直接失败，此时传
# FOLDESK_DISABLE_SWIFT_SANDBOX=1 关闭它即可，本机正常构建不受影响。
SWIFT_BUILD_ARGS=(-c release)
if [[ "${FOLDESK_DISABLE_SWIFT_SANDBOX:-0}" == "1" ]]; then
    SWIFT_BUILD_ARGS+=(--disable-sandbox)
fi
swift build "${SWIFT_BUILD_ARGS[@]}"

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

# 默认使用不会弹钥匙串授权框的 ad-hoc 签名。需要本机受信的自签证书时，
# 显式传入 FOLDESK_USE_LOCAL_CERT=1，避免无人值守构建永久卡在 codesign。
LOCAL_CERT="Foldesk Local Dev Code Signing"
if [[ "${FOLDESK_USE_LOCAL_CERT:-0}" == "1" ]] && \
   security find-identity -v -p codesigning 2>/dev/null | grep -q "$LOCAL_CERT"; then
    SIGN_IDENTITY="$LOCAL_CERT"
else
    SIGN_IDENTITY="-"
fi

# --- Finder Sync 扩展 ---
# 必须由原生 Xcode app-extension target 构建。直接用 swiftc 手工链接虽然能让
# 菜单显示，但缺少扩展动作调度所需的构建语义，Finder 点击后不会回调 selector。
NATIVE_DERIVED_DIR="$PROJECT_DIR/.build/native-findersync"
xcodebuild \
    -project "$PROJECT_DIR/Native/FoldeskNative.xcodeproj" \
    -scheme FoldeskFinderSync \
    -configuration Release \
    -derivedDataPath "$NATIVE_DERIVED_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build >/dev/null
NATIVE_EXTENSION="$NATIVE_DERIVED_DIR/Build/Products/Release/FoldeskFinderSync.appex"
if [[ ! -d "$NATIVE_EXTENSION" ]]; then
    echo "未找到原生 Finder Sync 构建产物：$NATIVE_EXTENSION" >&2
    exit 1
fi
mkdir -p "$PLUGINS_DIR"
/usr/bin/ditto "$NATIVE_EXTENSION" "$EXTENSION_DIR"

# 主程序与扩展版本保持一致，防止系统继续使用旧扩展缓存。
APP_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP_BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_SHORT_VERSION" "$EXTENSION_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_VERSION" "$EXTENSION_DIR/Contents/Info.plist"

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

# 嵌套代码必须先签扩展，再签宿主，而且使用同一个签名身份。
codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --entitlements "Sources/FoldeskFinderSync/FinderSync.entitlements" \
    --identifier "com.foldesk.mac.findersync" \
    --requirements '=designated => identifier "com.foldesk.mac.findersync"' \
    "$EXTENSION_DIR"

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

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# 提醒：本脚本产出的是**本机自用**构建。
# 若签名身份回退为 ad-hoc（"-"），该 .app 拷到别人机器上会被 Gatekeeper 拦下。
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "⚠️  使用 ad-hoc 签名：仅供本机使用，分发给他人需 Developer ID + 公证。" >&2
fi

echo "$APP_DIR"
