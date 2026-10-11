#!/bin/zsh
# Foldesk 右键菜单自检（只读，不会改动任何文件）
#
# 用途：右键菜单不出现、或点了没反应时，一次性看清「扩展有没有被系统加载」
# 与「设置页的配置有没有被扩展读到」。这两件事是分开的，症状却很像。
#
#   ./scripts/diagnose-finder-menu.sh                # 只检查
#   ./scripts/diagnose-finder-menu.sh --restart-finder  # 检查后重启访达刷新扩展
set -uo pipefail

APP="/Applications/Foldesk.app"
EXT="$APP/Contents/PlugIns/FoldeskFinderSync.appex"
EXT_ID="com.foldesk.mac.findersync"
REAL_CONFIG="$HOME/Library/Application Support/Foldesk/findersync.json"
CONTAINER_CONFIG="$HOME/Library/Containers/com.foldesk.mac.FinderSync/Data/Library/Application Support/Foldesk/findersync.json"

RESTART_FINDER=false
for arg in "$@"; do
    case "$arg" in
        --restart-finder) RESTART_FINDER=true ;;
        -h|--help) echo "用法：$0 [--restart-finder]"; exit 0 ;;
        *) echo "未知参数：$arg" >&2; exit 2 ;;
    esac
done

pass=0; fail=0; tips=()
ok()   { echo "  ✅ $1"; (( pass++ )) }
bad()  { echo "  ❌ $1"; (( fail++ )) }
warn() { echo "  ⚠️  $1" }
tip()  { tips+=("$1") }

echo "Foldesk 右键菜单自检"
echo "===================="

# ── 1. 安装位置 ──────────────────────────────────────────────────────────
echo
echo "1) 安装位置"
if [[ -d "$APP" ]]; then
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
    build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
    ok "已安装 /Applications/Foldesk.app（版本 $version build $build）"
else
    bad "未安装到 /Applications —— 请先运行 ./scripts/install-local.sh"
    tip "系统只扫描 /Applications（或 ~/Applications）里的应用，桌面上的副本不生效。"
fi

if [[ -d "$HOME/Applications/Foldesk.app" ]]; then
    warn "~/Applications 下还有一份副本，会与 /Applications 争用同一入口，建议移除"
fi

# ── 2. 扩展包完整性 ──────────────────────────────────────────────────────
echo
echo "2) 扩展包完整性"
if [[ -d "$EXT" ]]; then
    ok "扩展已打包：FoldeskFinderSync.appex"
    if [[ -f "$EXT/Contents/Resources/Templates/Empty.xlsx" \
       && -f "$EXT/Contents/Resources/Templates/Empty.docx" \
       && -f "$EXT/Contents/Resources/Templates/Empty.pptx" ]]; then
        ok "Office 空白模板齐全（新建 Word/Excel/PPT 依赖它）"
    else
        bad "扩展内缺少 Office 模板，新建 Office 文件会失败"
    fi
else
    bad "扩展包不存在 —— 构建产物不完整，请重新运行 ./scripts/build-app.sh"
fi

# ── 3. 扩展是否被系统加载 ────────────────────────────────────────────────
echo
echo "3) 扩展运行状态"
if pgrep -f "FoldeskFinderSync.appex/Contents/MacOS/FoldeskFinderSync" >/dev/null 2>&1; then
    ok "扩展进程正在运行（说明系统已加载它）"
else
    bad "扩展进程未运行 —— 右键菜单不会出现"
    tip "打开一次 Foldesk，再到「系统设置 → 通用 → 登录项与扩展 → 访达扩展」勾选 Foldesk 右键菜单。"
    tip "仍不行就运行 ./scripts/install-local.sh --skip-build 重新注册，然后重启访达。"
fi

pluginkit_out="$(pluginkit -m -v -i "$EXT_ID" 2>&1 || true)"
if echo "$pluginkit_out" | grep -q "unauthorized discovery flag"; then
    warn "当前权限下无法查询插件注册表（跳过这一项，以进程状态为准）"
elif echo "$pluginkit_out" | grep -q "$EXT_ID"; then
    ok "插件注册表里存在 $EXT_ID"
else
    bad "插件注册表里找不到 $EXT_ID"
    tip "运行 ./scripts/install-local.sh --skip-build 重新注册扩展。"
fi

# ── 4. 配置有没有被扩展读到 ──────────────────────────────────────────────
echo
echo "4) 配置一致性（设置页改动为什么没生效，看这里）"
if [[ -f "$REAL_CONFIG" ]]; then
    ok "真实配置存在：~/Library/Application Support/Foldesk/findersync.json"
    dirs=$(/usr/bin/python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print('、'.join(x['name'] for x in d.get('favoriteDirs',[])) or '（空）')" "$REAL_CONFIG" 2>/dev/null || echo "?")
    types=$(/usr/bin/python3 -c "import json,sys;d=json.load(open(sys.argv[1]));t=d.get('newFileTemplates',{});print('启用 %d 项' % sum(1 for v in t.values() if v))" "$REAL_CONFIG" 2>/dev/null || echo "?")
    echo "     常用目录：$dirs"
    echo "     新建类型：$types"
else
    warn "尚无配置文件，扩展会用内置默认值（下载 / 桌面 / 文稿）"
fi

if [[ -f "$CONTAINER_CONFIG" ]]; then
    bad "扩展容器里存在另一份配置，两边可能不一致："
    echo "     ~/Library/Containers/com.foldesk.mac.FinderSync/Data/Library/Application Support/Foldesk/findersync.json"
    tip "这是修复前的旧行为残留，删掉容器里那一份即可（不影响用户数据）。"
else
    ok "扩展没有在沙盒容器里另建配置（路径一致）"
fi

# ── 5. 系统门禁 ──────────────────────────────────────────────────────────
echo
echo "5) 系统门禁（Gatekeeper）"
if spctl -a -vvv "$APP" >/dev/null 2>&1; then
    ok "已通过 Gatekeeper 校验"
else
    warn "本机构建为 ad-hoc 签名，Gatekeeper 判定 rejected"
    echo "     本机自用没问题；拷给别人会被拦（需 Developer ID + 公证）。"
fi

# ── 6. 访达 ──────────────────────────────────────────────────────────────
echo
echo "6) 访达"
if pgrep -x Finder >/dev/null 2>&1; then
    ok "访达正在运行"
else
    bad "访达未运行"
fi

# ── 结果 ─────────────────────────────────────────────────────────────────
echo
echo "===================="
echo "通过 $pass 项，问题 $fail 项"

if (( ${#tips[@]} > 0 )); then
    echo
    echo "建议操作："
    for t in "${tips[@]}"; do
        echo "  • $t"
    done
fi

if [[ "$RESTART_FINDER" == true ]]; then
    echo
    echo "正在重启访达以重新加载扩展…"
    killall Finder 2>/dev/null || true
    sleep 2
    echo "访达已重启。请在任意文件夹空白处右键查看菜单。"
else
    echo
    echo "提示：改动扩展后需要让访达重新加载。加 --restart-finder 参数可直接重启访达。"
fi

exit $(( fail > 0 ? 1 : 0 ))
