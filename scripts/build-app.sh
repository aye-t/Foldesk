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

if [[ -d "$ICONSET_DIR" ]]; then
    rm -rf "$ICONSET_DIR"
fi
mkdir -p "$ICONSET_DIR"
sips -z 16 16 "Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "Resources/FoldeskIcon.png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS_DIR/Resources/FoldeskIcon.icns"

# Keep a stable designated requirement for local development builds. Without
# this, ad-hoc signing defaults to the binary's changing CDHash and macOS treats
# every rebuild as a different app in Accessibility privacy settings.
codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "com.foldesk.mac"' \
    "$APP_DIR"

echo "$APP_DIR"
