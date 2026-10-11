#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/dist/Foldesk.app"
INSTALL_APP="/Applications/Foldesk.app"
USER_APPLICATIONS_APP="${HOME:?}/Applications/Foldesk.app"
TRASH_DIR="${HOME:?}/.Trash"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SKIP_BUILD=false
OPEN_AFTER_INSTALL=true

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        --no-open) OPEN_AFTER_INSTALL=false ;;
        *) echo "用法：$0 [--skip-build] [--no-open]" >&2; exit 2 ;;
    esac
done

if [[ "$SKIP_BUILD" != true ]]; then
    "$PROJECT_DIR/scripts/build-app.sh" >/dev/null
fi

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "未找到构建产物：$SOURCE_APP" >&2
    exit 1
fi

# 在移动现有安装之前验证新包，失败时保留可用的旧版本。
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/.build/foldesk-install.XXXXXX")"
/usr/bin/ditto "$SOURCE_APP" "$STAGING_DIR/Foldesk.app"
/usr/bin/codesign --verify --deep --strict "$STAGING_DIR/Foldesk.app"

pkill -x Foldesk >/dev/null 2>&1 || true
pkill -f '/FoldeskFinderSync.appex/Contents/MacOS/FoldeskFinderSync' >/dev/null 2>&1 || true
mkdir -p "$TRASH_DIR"

archive_existing_app() {
    local source="$1"
    local label="$2"
    if [[ -d "$source" ]]; then
        local destination="$TRASH_DIR/Foldesk-$label-$TIMESTAMP.app"
        "$LSREGISTER" -u "$source" || true
        mv "$source" "$destination"
        echo "已把旧版本移到废纸篓：$destination"
    fi
}

# 同一 Bundle ID 的多个副本会让 LaunchServices 随机命中旧服务表。
# 先把旧副本移到废纸篓（可恢复），再安装唯一的 /Applications 版本。
archive_existing_app "$INSTALL_APP" "Applications"
archive_existing_app "$USER_APPLICATIONS_APP" "UserApplications"
mv "$STAGING_DIR/Foldesk.app" "$INSTALL_APP"
rmdir "$STAGING_DIR"

# dist 是构建产物，不应与安装版争用同一个服务入口。
"$LSREGISTER" -u "$SOURCE_APP" || true
"$LSREGISTER" -f "$INSTALL_APP"
/usr/bin/pluginkit -a "$INSTALL_APP/Contents/PlugIns/FoldeskFinderSync.appex"
/System/Library/CoreServices/pbs -flush
if [[ "$OPEN_AFTER_INSTALL" == true ]]; then
    /usr/bin/open "$INSTALL_APP"
fi

echo "已安装唯一版本：$INSTALL_APP"
