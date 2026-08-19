# Foldesk 上线前审查报告

> 审查范围：全量源码、测试用例、文档（README / 设置页 / 右键菜单页）、真实用户操作流程
> 审查日期：2026-08-19
> 构建验证：`swift build -c release` ✅ 通过（16.56s，无错误）；`swift test` ✅ 8 个用例全绿
> 说明：构建在本环境需 `--disable-sandbox`（受限沙箱禁止 `sandbox_apply`），用户本机正常 `swift build` 已验证可产出 `~/Applications/Foldesk.app`

---

## 一、今日上线阻断性问题（Blocker）

> “今日上线”分两种理解，阻断性不同，已分别标注。

### B1. 分发签名未过公证（仅在“对外分享给他人用”时阻断）
- 现状：`scripts/build-app.sh` 签名优先级为「本机自签证书 `Foldesk Local Dev Code Signing` → 否则 ad-hoc（`-`）」。
- 后果：ad-hoc / 本地自签应用**未经过 Apple Developer ID 公证**，其他机器运行会被 Gatekeeper 拦截（“无法打开，因为无法验证开发者”）。
- 影响：
  - 若“上线”= **在自己机器录视频演示** → **不阻断**，应用本机可正常跑。
  - 若“上线”= **社媒分享让观众下载使用** → **真阻断**，别人大概率打不开。
- 建议：仅本地演示则无需处理；若要分发，需 Developer ID 证书 + `xcrun notarytool` 公证 + 装订（staple）。

### B2. README 把用户引导到已废弃的 Finder Sync 扩展路径（阻断首跑体验）
- 现状：
  - `scripts/build-app.sh` **仍在编译并嵌入 `FoldeskFinderSync.appex`** 到 `PlugIns/`。
  - `README.md` 第 42–65 行把「Finder 右键菜单扩展」写成主功能，并给出「系统设置 → 隐私 → 扩展 → 访达 → 勾选 Foldesk」的启用步骤。
  - 但 git baseline 已注明“Foldesk 在加入 Finder 右键扩展之前的版本”，**当前实际可用的右键机制是 NSServices**（`Resources/Info.plist` 的 10 项 `NSServices`，`ServicesHandler.swift` 注释亦确认“无需公证/开发者证书即可被系统发现，是 Finder Sync 扩展在自签环境下的可用替代”）。
  - 右侧「右键服务」页（`FinderMenuPage.swift`）自身已正确描述为“通过 macOS「服务」”，与 README 矛盾。
- 后果：用户照 README 第 3 步去启用 Finder Sync 扩展，而该 .appex 未公证、在干净机器上根本加载不了 → **卡在启用步骤，以为软件坏了**。
- 建议：
  1. 重写 README 的「Finder 右键菜单扩展」章节为 NSServices 路径（把 app 放 `/Applications` → 访达右键 → 服务 → Foldesk 动作）。
  2. 从 `build-app.sh` 移除 `.appex` 打包（死重 + 误导），或明确标注 Finder Sync 已废弃、仅保留 NSServices。

### B3. 核心能力在未授权时静默失效 + 误导性提示（阻断“看起来能用”）
- 现状：收起 / 分屏 / 恢复位置尺寸**依赖「辅助功能」权限**。
  - `AppState.restore()` 在未授权时仍弹 `toast = "正在恢复 X 个窗口"`，但实际无 AX 权限无法回位 → **假成功提示**。
  - `applyActiveWorkspaceLayout` 有 `guard accessibilityGranted else` 拦截；但 `foldAll` / `restore` 路径没有同等的前置拦截，只靠 `manager.hide()`（能藏不能精确恢复）。
- 后果：首跑未授权就演示“收起全部 → 恢复”，恢复不动却提示成功 → 视频/分享观感像 bug。
- 建议：`foldAll` / `restore` 入口加 `accessibilityGranted` 校验，未授权时弹引导而非假成功；首屏 `PermissionBanner` 强化为“不授权则核心功能不可用”。

---

## 二、用户体验疑点（UX Doubts）

### U1. NSServices 可发现性差 + 首次注册时机不确定
- 10 项服务仅在 **访达（含桌面，即 Finder）右键的「服务」子菜单**可见，文件选择器/浏览器上传框等不出现。
- 全新构建后可能需把 app 移到 `/Applications` 并触发 LaunchServices 注册（重登录或 `lsregister`）才会显示，首次演示可能“找不到服务”。

### U2. 「右键服务」页暴露了不存在的功能配置（死配置）
- `FinderMenuPage.swift` 中“常用目录（规划中）”“用指定 App 打开（规划中）”**渲染成可增删的完整 UI**（有添加/删除按钮、有 sheet），但其配置写入 `findersync.json` 后**没有任何服务消费**（Info.plist 的 NSServices 仅含 新建/复制路径/复制文件名/压缩/解压/彻底删除）。
- 用户加了目录/App 却永远用不上 → 误导。建议：规划中区块仅展示说明、禁用编辑，或加“尚未启用”遮罩。

### U3. 屏幕录制权限提示文案与状态相反（疑似 bug）
- `AppState.requestScreenRecordingPermission()`：
  ```swift
  let granted = manager.requestScreenRecordingPermission()
  refreshPermissions()
  if granted && !screenRecordingGranted {
      toast = "屏幕录制已开启，重新启动 Foldesk 后生效"
  }
  ```
  `!screenRecordingGranted` 为 true 时（即**尚未授权**）才弹“已开启…”，文案与真实状态相反；且“辅助功能”路径无对应确认提示（不一致）。

### U4. 默认无全局快捷键、默认无登录项
- `summonKeyCode = -1`（默认不绑定唤起键）；无 LaunchAgent / LoginItem。
- 后果：重启后 Foldesk 不自动运行，“离开前一键收起”的心智模型对健忘用户失效。建议默认提供登录项开关（或首次运行询问）。

### U5. 进入工作区不会自动分屏
- 进入工作区仅最小化无关窗口 + 弹出悬浮控制器；**分屏需手动点「开始分屏」**。首次用户易以为“工作区=自动排布”。

### U6. 收起全部默认不排除任何应用
- `excludedBundleIDs` 默认空 → 会一并隐藏正在进行的会议（腾讯会议/Zoom）、音乐等。建议给少量合理默认排除（或首屏引导用户勾选）。

---

## 三、默认 / 背景相关缺陷（Default & Background Defects）

### D1. `confirmRiskyActions` 是死偏好（确认过 `grep` 全仓）
- 仅出现在 `Models.swift`（默认 + `Codable` 解码）与 `SettingsPage` 开关 + `onChange` 持久化；**从未在任何操作路径被读取**。
- 即“高风险操作前确认”开关**无任何实际效果**（真正的危险操作如 `permanentDelete`、批量退出各自写死了 NSAlert，不受此开关控制）。

### D2. `keepMenuBar` 是死偏好（确认过 `grep` 全仓）
- 仅出现在 `Models.swift`（默认 + 解码），从未被任何代码引用 → 纯死字段。

### D3. 构建可重现性依赖本机证书
- `build-app.sh` 依赖名为 `Foldesk Local Dev Code Signing` 的本地自签证书；其他机器静默回退 ad-hoc（`-`）。换机构建产物签名不一致，且每次 ad-hoc 重建 CDHash 变化（已在脚本注释中部分规避，但仅在存在本地证书时）。

### D4. 测试覆盖极薄 + 无 CI
- 仅 8 个纯逻辑单测：`FloatingPanelGeometry`（2）、`ServicesHandler`（3：建文件不覆盖、压缩解压往返、递归目录）、`WorkspaceWindowSelection`（3：主窗口选择逻辑）。
- **无** AppState 行为、工作区激活/退出、收起-恢复、分屏摆位、权限流、浮窗拖拽等任何集成/行为测试。
- 无 CI 配置、无测试门禁。今日上线前至少应补「收起→恢复」与「分屏」smoke 测试。

---

## 四、审查结论与优先级

| 优先级 | 项 | 是否阻断今日（仅本机录视频） | 是否阻断（对外分享分发） |
|---|---|---|---|
| P0 | B1 公证签名 | 否 | **是** |
| P0 | B2 README/扩展误导 | 演示前需改文案 | 是（观众会卡住） |
| P0 | B3 未授权假成功提示 | 是（观感像坏） | 是 |
| P1 | U2 死配置暴露 | 否 | 否（但掉价） |
| P1 | U3 录屏提示文案 bug | 否 | 否 |
| P1 | D1/D2 死偏好 | 否 | 否 |
| P2 | U1/U4/U5/U6、D3/D4 | 否 | 否 |

**一句话建议**：本机录视频完全可行（构建/测试已绿）；但发视频前务必 (1) 改 README 去掉 Finder Sync 启用步骤、(2) 给收起/恢复加未授权拦截避免假成功、(3) 右键服务页把“规划中”区块设为只读。若要把 app 发给观众，必须先做 Developer ID 公证。
