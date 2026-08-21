import SwiftUI
import UniformTypeIdentifiers

struct RecentPage: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "最近收起", subtitle: "回到任意一次最近保存的窗口状态")
            if state.records.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "还没有收起记录", message: "点击“收起全部”后，Foldesk 会在本地保存最近 10 次窗口状态。")
            } else {
                List {
                    ForEach(state.records) { record in
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10).fill(Color.foldeskBlue.opacity(0.09))
                                Image(systemName: record.restored ? "checkmark.arrow.trianglehead.counterclockwise" : "clock.arrow.circlepath")
                                    .foregroundStyle(Color.foldeskBlue)
                            }
                            .frame(width: 46, height: 46)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.name).font(.headline)
                                Text("\(record.applicationCount) 个应用 · \(record.windows.count) 个窗口 · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(Array(Set(record.windows.map(\.appName))).sorted().prefix(5).joined(separator: "、"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if record.restored {
                                Text("已恢复").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("保存为工作区") {
                                state.workspaces.append(
                                    WorkspaceItem(id: UUID(), name: record.name, symbol: "briefcase.fill", colorName: "blue", createdAt: Date(), windows: record.windows)
                                )
                                state.savePreferences()
                            }
                            Button("恢复") { state.restore(record) }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.foldeskBlue)
                        }
                        .padding(.vertical, 8)
                    }
                    .onDelete(perform: state.deleteRecords)
                }
                .listStyle(.inset)
                .safeAreaPadding(.bottom, 76)
            }
        }
    }
}

struct WorkspacesPage: View {
    @EnvironmentObject private var state: AppState
    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "我的工作区", subtitle: "保存任务需要的窗口和布局，下次一键继续")
            if !state.activeWorkspaces.isEmpty {
                VStack(spacing: 8) {
                    ForEach(state.activeWorkspaces) { workspace in
                        ActiveWorkspaceBanner(workspace: workspace)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            if state.workspaces.isEmpty {
                EmptyState(symbol: "rectangle.3.group", title: "创建第一个工作区", message: "整理好当前桌面后，选择这项任务需要的具体窗口并保存。")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(state.workspaces) { workspace in
                            WorkspaceCard(workspace: workspace)
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 76)
                }
            }
        }
    }
}

private struct ActiveWorkspaceBanner: View {
    @EnvironmentObject private var state: AppState
    let workspace: WorkspaceItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("使用中：\(workspace.name)")
                    .font(.headline)
                Text("工作区可以同时选择；退出时会保留其他工作区正在使用的应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新应用布局") { state.reapplyWorkspace(workspace) }
            Button(state.isFloatingWorkspaceVisible(workspace.id) ? "隐藏悬浮标签" : "显示悬浮标签") {
                state.toggleFloatingWorkspacePanel(for: workspace.id)
            }
            Menu("退出工作区") {
                Button("退出并收起窗口") { state.endWorkspace(workspace.id) }
                Button("退出并正常关闭成员应用", role: .destructive) {
                    state.endWorkspace(workspace.id, quitApplications: true)
                }
            }
        }
        .padding(14)
        .background(Color.green.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.green.opacity(0.28)))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}

struct WorkspaceCard: View {
    @EnvironmentObject private var state: AppState
    let workspace: WorkspaceItem
    @State private var showsControls = false

    private var color: Color {
        switch workspace.colorName {
        case "purple": .purple
        case "orange": .orange
        case "green": .green
        default: .foldeskBlue
        }
    }

    var body: some View {
        let isActive = state.isWorkspaceActive(workspace.id)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(color.opacity(0.12))
                    Image(systemName: workspace.symbol).font(.title2).foregroundStyle(color)
                }
                .frame(width: 48, height: 48)
                if isActive {
                    Text("使用中")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.1))
                        .clipShape(Capsule())
                }
                Spacer()
                Menu {
                    Button("编辑") { state.beginEditingWorkspace(workspace) }
                    Button("复制") { state.duplicateWorkspace(workspace) }
                    Button("删除", role: .destructive) { state.deleteWorkspace(workspace) }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            Text(workspace.name).font(.title3.weight(.semibold))
            Text("\(workspace.applicationCount) 个应用 · \(workspace.windows.count) 个窗口")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(workspace.applicationNames.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("自动打开 \(workspace.autoLaunchIDs.count) 个 · 其余按需 · \(workspace.assignedLayout.rawValue)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if workspace.windows.isEmpty {
                Text("只启动应用，不恢复具体窗口")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(workspace.windows.prefix(3).enumerated()), id: \.offset) { _, window in
                        Label("\(window.appName) · \(window.title)", systemImage: "macwindow")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if workspace.windows.count > 3 {
                        Text("另有 \(workspace.windows.count - 3) 个窗口")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            DisclosureGroup(isExpanded: $showsControls) {
                WorkspaceControlList(workspace: workspace)
                    .padding(.top, 8)
            } label: {
                Label("应用与窗口控制", systemImage: "switch.2")
                    .font(.caption.weight(.semibold))
            }
            .disclosureGroupStyle(.automatic)
            Spacer(minLength: 0)
            Button {
                if isActive {
                    state.endWorkspace(workspace.id)
                } else {
                    state.openWorkspace(workspace)
                }
            } label: {
                Label(
                    isActive ? "退出工作区" : "进入工作区",
                    systemImage: isActive ? "rectangle.portrait.and.arrow.right" : "play.fill"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isActive ? Color.foldeskRed : color)
        }
        .padding(16)
        .frame(minHeight: 270)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

struct WorkspaceControlList: View {
    @EnvironmentObject private var state: AppState
    let workspace: WorkspaceItem
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 7 : 9) {
            ForEach(workspace.memberApplications) { member in
                WorkspaceMemberControlRow(
                    workspace: workspace,
                    member: member,
                    compact: compact
                )
            }
        }
    }
}

private struct WorkspaceMemberControlRow: View {
    @EnvironmentObject private var state: AppState
    let workspace: WorkspaceItem
    let member: WorkspaceApplication
    let compact: Bool

    private var running: RunningAppItem? {
        state.runningApplication(for: member)
    }

    var body: some View {
        HStack(spacing: 8) {
            FirstMouseApplicationButton(
                image: icon,
                title: member.name,
                subtitle: memberStatus,
                subtitleColor: NSColor(memberStatusColor)
            ) {
                state.showWorkspaceMember(member, in: workspace.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: compact ? 30 : 34)
            .help(running == nil ? "打开 \(member.name)" : "显示并切换到 \(member.name)")
            controlButton("eye", help: running == nil ? "打开应用" : "显示应用") {
                state.showWorkspaceMember(member, in: workspace.id)
            }
            controlButton("minus", help: "最小化全部窗口", disabled: running == nil) {
                state.minimizeWorkspaceMember(member)
            }
            controlButton("arrow.up.left.and.arrow.down.right", help: "放大或还原全部窗口", disabled: running == nil) {
                state.zoomWorkspaceMember(member)
            }
            controlButton("xmark", help: "关闭全部窗口", disabled: running == nil, destructive: true) {
                state.closeWorkspaceMemberWindows(member)
            }
            controlButton("power", help: "正常退出应用", disabled: running == nil, destructive: true) {
                state.quitWorkspaceMember(member)
            }
        }
        .padding(compact ? 8 : 9)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var icon: NSImage {
        if let running { return running.icon }
        if let path = member.bundlePath {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ??
            NSImage(size: NSSize(width: 28, height: 28))
    }

    private var memberStatus: String {
        guard let running else { return "未运行" }
        let count = running.windows.count
        guard count > 0 else { return "运行中 · 无窗口" }
        if running.windows.allSatisfy(\.isMinimized) {
            return "已最小化 · \(count) 个窗口"
        }
        if running.isActive {
            return "前台 · \(count) 个窗口"
        }
        return "可见 · \(count) 个窗口"
    }

    private var memberStatusColor: Color {
        guard let running else { return .secondary }
        if running.windows.allSatisfy(\.isMinimized) {
            return .secondary
        }
        if running.isActive {
            return .foldeskBlue
        }
        return .foldeskGreen
    }

    private func controlButton(
        _ symbol: String,
        help: String,
        disabled: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .frame(width: 20, height: 20)
                .foregroundStyle(destructive ? Color.foldeskRed : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
    }
}

private enum BatchScope: String, CaseIterable {
    case applications = "应用操作"
    case windows = "窗口操作"
}

struct BatchPage: View {
    @EnvironmentObject private var state: AppState
    @State private var scope: BatchScope = .applications
    @State private var selectedApplicationIDs: Set<String> = []
    @State private var confirmClose = false
    @State private var confirmQuit = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "批量操作", subtitle: "应用和窗口分开选择，避免关闭窗口与退出应用混淆")

            Picker("操作对象", selection: $scope) {
                ForEach(BatchScope.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .padding(.bottom, 14)

            if scope == .applications {
                applicationToolbar
                applicationList
            } else {
                windowToolbar
                windowList
            }
        }
        .alert("关闭选中的窗口？", isPresented: $confirmClose) {
            Button("取消", role: .cancel) {}
            Button("关闭窗口", role: .destructive) { state.performBatch(.close) }
        } message: {
            Text("只关闭窗口，不退出应用。应用仍可能继续显示在 Dock 中；未保存内容由原应用提示。")
        }
        .alert("退出选中的应用？", isPresented: $confirmQuit) {
            Button("取消", role: .cancel) {}
            Button("正常退出", role: .destructive) {
                state.quitApps(selectedApplicationIDs)
                selectedApplicationIDs.removeAll()
            }
        } message: {
            Text("将退出 \(selectedApplicationIDs.count) 个应用及其全部窗口。未保存内容由原应用提示；Foldesk 自身始终保持运行。")
        }
    }

    private var applicationToolbar: some View {
        HStack {
            Text("已选择 \(selectedApplicationIDs.count) 个应用")
                .font(.headline)
            Spacer()
            Button("全选") { selectedApplicationIDs = Set(state.applications.map(\.id)) }
            Button("清除选择") { selectedApplicationIDs.removeAll() }
            Button("显示") { state.performApplicationBatch(.show, ids: selectedApplicationIDs) }
                .disabled(selectedApplicationIDs.isEmpty)
            Button("隐藏") { state.performApplicationBatch(.hide, ids: selectedApplicationIDs) }
                .disabled(selectedApplicationIDs.isEmpty)
            Button("最小化窗口") { state.performApplicationBatch(.minimize, ids: selectedApplicationIDs) }
                .disabled(selectedApplicationIDs.isEmpty)
            Button("退出应用…", role: .destructive) { confirmQuit = true }
                .disabled(selectedApplicationIDs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var applicationList: some View {
        List(state.applications) { app in
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { selectedApplicationIDs.contains(app.id) },
                    set: { enabled in
                        if enabled { selectedApplicationIDs.insert(app.id) }
                        else { selectedApplicationIDs.remove(app.id) }
                    }
                ))
                .toggleStyle(.checkbox)
                AppIcon(image: app.icon, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 14, weight: .medium))
                    Text(app.windows.isEmpty ? "后台运行，无窗口" : "\(app.windows.count) 个窗口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("运行中")
                    .font(.caption)
                    .foregroundStyle(.green)
                if isRisky(app) {
                    Label("可能未保存", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 5)
        }
        .listStyle(.inset)
        .safeAreaPadding(.bottom, 76)
    }

    private var windowToolbar: some View {
        HStack {
            Text("已选择 \(state.selectedWindowIDs.count) 个窗口")
                .font(.headline)
            Spacer()
            Button("全选") {
                state.selectedWindowIDs = Set(state.applications.flatMap(\.windows).map(\.id))
            }
            Button("清除选择") { state.selectedWindowIDs.removeAll() }
            Button("显示") { state.performBatch(.show) }
                .disabled(state.selectedWindowIDs.isEmpty)
            Button("最小化") { state.performBatch(.minimize) }
                .disabled(state.selectedWindowIDs.isEmpty)
            Button("放大") { state.performBatch(.zoom) }
                .disabled(state.selectedWindowIDs.isEmpty)
            Button("关闭窗口…", role: .destructive) { confirmClose = true }
                .disabled(state.selectedWindowIDs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var windowList: some View {
        List {
            ForEach(state.applications.filter { !$0.windows.isEmpty }) { app in
                Section {
                    ForEach(app.windows) { window in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { state.selectedWindowIDs.contains(window.id) },
                                set: { _ in state.toggleSelected(window) }
                            ))
                            .toggleStyle(.checkbox)
                            AppIcon(image: app.icon, size: 24)
                            Text(window.title).lineLimit(1)
                            Spacer()
                            Text(window.isMinimized ? "已最小化" : "可见")
                                .font(.caption)
                                .foregroundStyle(window.isMinimized ? .secondary : Color.green)
                            if isRisky(app) {
                                Label("可能未保存", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("\(app.name) · \(app.windows.count) 个窗口")
                }
            }
        }
        .listStyle(.inset)
        .safeAreaPadding(.bottom, 76)
    }

    private func isRisky(_ app: RunningAppItem) -> Bool {
        ["Word", "Excel", "PowerPoint", "Photoshop", "Pages", "Numbers"]
            .contains { app.name.localizedCaseInsensitiveContains($0) }
    }
}

struct SettingsPage: View {
    @EnvironmentObject private var state: AppState
    private let appColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置", subtitle: "调整外观、收起方式、权限与安全规则")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsSectionCard(title: "外观") {
                        Picker("显示模式", selection: $state.preferences.appearance) {
                            ForEach(AppAppearance.allCases) { appearance in
                                Label(appearance.title, systemImage: appearance.symbol)
                                    .tag(appearance)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("“跟随系统”会随 macOS 的外观设置自动切换。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsSectionCard(title: "悬浮控制台") {
                        Toggle(
                            "显示悬浮控制台",
                            isOn: Binding(
                                get: { state.preferences.showFloatingConsole },
                                set: { state.setFloatingConsoleVisibility($0) }
                            )
                        )
                        Text("收起时仅显示 Foldesk 图标、回到桌面按钮和展开入口；展开后可查看窗口与工作区。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsSectionCard(title: "权限") {
                    PermissionRow(
                        symbol: "accessibility",
                        title: "辅助功能",
                        detail: "用于聚焦、缩小与关闭其他应用窗口",
                        granted: state.accessibilityGranted
                    ) {
                        state.requestAccessibilityPermission()
                    } manageAction: {
                        state.manageAccessibilityPermission()
                    }
                    PermissionRow(
                        symbol: "record.circle",
                        title: "屏幕录制",
                        detail: "仅用于在本机生成真实窗口缩略图",
                        granted: state.screenRecordingGranted
                    ) {
                        state.requestScreenRecordingPermission()
                    } manageAction: {
                        state.manageScreenRecordingPermission()
                    }
                    }

                    SettingsSectionCard(title: "收起与恢复") {
                        HStack {
                            Text("默认收起方式")
                            Spacer()
                            Picker("", selection: $state.preferences.foldMode) {
                                ForEach(FoldMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        Divider()
                        Toggle("收起后显示恢复浮层", isOn: $state.preferences.showRecoveryOverlay)
                        Toggle("记住窗口位置", isOn: $state.preferences.rememberPosition)
                        Toggle("记住窗口尺寸", isOn: $state.preferences.rememberSize)
                        Toggle("保存最近 10 次收起记录", isOn: $state.preferences.saveHistory)
                    }

                    SettingsSectionCard(title: "菜单栏") {
                        Toggle("在菜单栏常驻 Foldesk 图标", isOn: $state.preferences.keepMenuBar)
                        Text("关闭后菜单栏图标会立即消失，只能通过 Dock 图标或快捷唤起打开主窗口。建议保持开启。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsSectionCard(title: "安全") {
                        Toggle("高风险操作前确认", isOn: $state.preferences.confirmRiskyActions)
                        Text("开启后，退出他人应用（单个退出 / 批量退出 / 结束工作区并退出）前会弹出确认。Foldesk 始终优先使用应用的正常退出流程，不默认强制退出。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsSectionCard(title: "快捷唤起") {
                        SummonHotkeyRow()
                        Text("设置后，即使 Foldesk 在后台，也能用该组合键唤出主窗口。需要已授予“辅助功能”权限。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsSectionCard(title: "排除应用") {
                        Text("选中的应用不会被“收起全部”影响。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: appColumns, alignment: .leading, spacing: 8) {
                            ForEach(state.applications) { app in
                                Toggle(isOn: Binding(
                                    get: { app.bundleIdentifier.map(state.preferences.excludedBundleIDs.contains) ?? false },
                                    set: { enabled in
                                        guard let id = app.bundleIdentifier else { return }
                                        if enabled { state.preferences.excludedBundleIDs.insert(id) }
                                        else { state.preferences.excludedBundleIDs.remove(id) }
                                    }
                                )) {
                                    HStack(spacing: 8) {
                                        AppIcon(image: app.icon, size: 22)
                                        Text(app.name).lineLimit(1)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 96)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: state.preferences.appearance) { state.savePreferences() }
            .onChange(of: state.preferences.foldMode) { state.savePreferences() }
            .onChange(of: state.preferences.showRecoveryOverlay) { state.savePreferences() }
            .onChange(of: state.preferences.rememberPosition) { state.savePreferences() }
            .onChange(of: state.preferences.rememberSize) { state.savePreferences() }
            .onChange(of: state.preferences.confirmRiskyActions) { state.savePreferences() }
            .onChange(of: state.preferences.keepMenuBar) { state.savePreferences() }
            .onChange(of: state.preferences.saveHistory) { state.savePreferences() }
            .onChange(of: state.preferences.excludedBundleIDs) { state.savePreferences() }
        }
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.58))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SummonHotkeyRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack {
            Text("全局唤起快捷键")
            Spacer()
            if state.isRecording {
                Button { state.cancelRecording() } label: {
                    Label("按下快捷键…", systemImage: "keyboard").foregroundStyle(.orange)
                }
            } else if state.summonKeyCode >= 0 {
                Button { state.startRecording() } label: {
                    Text(verbatim: state.summonShortcutDescription)
                }
                .buttonStyle(.bordered)
                Button("清除") { state.clearSummonShortcut() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.foldeskRed)
            } else {
                Button { state.startRecording() } label: {
                    Text("点击设置")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void
    let manageAction: () -> Void

    var body: some View {
        HStack {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(Color.foldeskBlue)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("取消授权…", action: manageAction)
            } else {
                Button("前往授权", action: action)
                Button("系统设置…", action: manageAction)
            }
        }
    }
}

struct NewWorkspaceSheet: View {
    @EnvironmentObject private var state: AppState
    let workspace: WorkspaceItem?
    @State private var name: String
    @State private var symbol: String
    @State private var selectedApplications: [WorkspaceApplication]
    @State private var selectedWindowIDs: Set<String> = []
    @State private var loadedExistingSelection = false
    private let symbols = ["briefcase.fill", "graduationcap.fill", "person.2.fill", "cup.and.saucer.fill", "paintbrush.fill"]

    init(workspace: WorkspaceItem? = nil) {
        self.workspace = workspace
        _name = State(initialValue: workspace?.name ?? "")
        _symbol = State(initialValue: workspace?.symbol ?? "briefcase.fill")
        let applications = workspace?.applications ??
            Self.legacyApplications(from: workspace?.windows ?? [])
        _selectedApplications = State(initialValue: applications)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(workspace == nil ? "新建工作区" : "编辑工作区").font(.title2.bold())
            Text("选择任务需要的应用和具体窗口。进入时会最小化无关窗口并弹出控制器；成员默认按需打开。")
                .foregroundStyle(.secondary)
            TextField("工作区名称，例如：论文模式", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                ForEach(symbols, id: \.self) { item in
                    Button { symbol = item } label: {
                        Image(systemName: item)
                            .frame(width: 38, height: 38)
                            .background(symbol == item ? Color.foldeskBlue : Color.primary.opacity(0.05))
                            .foregroundStyle(symbol == item ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                applicationPicker

                Image(systemName: "arrow.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(height: 300)

                selectedApplicationsList
            }

            Text("已选择 \(selectedApplicationIDs.count) 个应用、\(selectedWindowIDs.count) 个具体窗口。未运行的应用仍会在打开工作区时启动。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { state.cancelWorkspaceEditor() }
                Button(workspace == nil ? "保存工作区" : "保存修改") {
                    state.saveCurrentWorkspace(
                        name: name,
                        symbol: symbol,
                        workspaceApplications: selectedApplications,
                        selectedWindowIDs: selectedWindowIDs,
                        editingWorkspaceID: workspace?.id
                    )
                }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.foldeskBlue)
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty ||
                        selectedApplications.isEmpty
                    )
            }
        }
        .padding(24)
        .frame(width: 760)
        .onAppear {
            loadExistingWindowSelection()
        }
    }

    private var applicationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("可用应用").font(.headline)
                Spacer()
                Button("选择其他应用…") {
                    chooseApplications()
                }
                .buttonStyle(.link)
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(state.applications.filter { !selectedApplicationIDs.contains($0.id) }) { app in
                        HStack {
                            AppIcon(image: app.icon, size: 24)
                            Text(app.name).lineLimit(1)
                            Spacer()
                            Button {
                                add(app)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Color.foldeskBlue)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(7)
                        .background(Color.primary.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .draggable(app.id)
                    }
                }
            }
            .frame(height: 300)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.panelBorder))
        }
        .frame(maxWidth: .infinity)
    }

    private var selectedApplicationsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("工作区包含").font(.headline)
                Spacer()
                Button("清空") {
                    selectedApplications.removeAll()
                    selectedWindowIDs.removeAll()
                }
                    .buttonStyle(.link)
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(selectedApplications) { app in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                AppIcon(image: icon(for: app), size: 24)
                                Text(app.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Spacer()
                                Button {
                                    remove(app)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            if let running = runningApplication(for: app), !running.windows.isEmpty {
                                ForEach(running.windows) { window in
                                    Toggle(isOn: Binding(
                                        get: { selectedWindowIDs.contains(window.id) },
                                        set: { selected in
                                            if selected { selectedWindowIDs.insert(window.id) }
                                            else { selectedWindowIDs.remove(window.id) }
                                        }
                                    )) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(window.title)
                                                .font(.caption)
                                                .lineLimit(1)
                                            Text("\(Int(window.frame.width)) × \(Int(window.frame.height))")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .padding(.leading, 31)
                                }
                            } else {
                                Text("当前没有窗口；打开工作区时只启动应用")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 31)
                            }
                        }
                        .padding(7)
                        .background(Color.foldeskBlue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(4)
            }
            .frame(height: 300)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.foldeskBlue.opacity(0.35)))
            .dropDestination(for: String.self) { items, _ in
                for id in items {
                    if let app = state.applications.first(where: { $0.id == id }) {
                        add(app)
                    }
                }
                return true
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var selectedApplicationIDs: Set<String> {
        Set(selectedApplications.map(\.id))
    }

    private func add(_ app: RunningAppItem) {
        let stableBundleURL = app.bundleIdentifier.flatMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        } ?? app.bundleURL
        add(
            WorkspaceApplication(
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                bundlePath: stableBundleURL?.path
            )
        )
        selectedWindowIDs.formUnion(app.windows.map(\.id))
    }

    private func add(_ app: WorkspaceApplication) {
        guard !selectedApplicationIDs.contains(app.id) else { return }
        selectedApplications.append(app)
    }

    private func remove(_ app: WorkspaceApplication) {
        if let running = runningApplication(for: app) {
            selectedWindowIDs.subtract(running.windows.map(\.id))
        }
        selectedApplications.removeAll { $0.id == app.id }
    }

    private func runningApplication(for app: WorkspaceApplication) -> RunningAppItem? {
        state.applications.first {
            if let bundleIdentifier = app.bundleIdentifier {
                return bundleIdentifier == $0.bundleIdentifier
            }
            return app.name == $0.name
        }
    }

    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.title = "选择要加入工作区的应用"
        panel.prompt = "加入工作区"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let bundle = Bundle(url: url)
            let displayName =
                bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ??
                url.deletingPathExtension().lastPathComponent
            add(
                WorkspaceApplication(
                    name: displayName,
                    bundleIdentifier: bundle?.bundleIdentifier,
                    bundlePath: url.path
                )
            )
        }
    }

    private func icon(for app: WorkspaceApplication) -> NSImage {
        if let path = app.bundlePath {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ??
            NSImage(size: NSSize(width: 32, height: 32))
    }

    private func loadExistingWindowSelection() {
        guard !loadedExistingSelection, let workspace else { return }
        loadedExistingSelection = true
        for member in selectedApplications {
            guard let running = runningApplication(for: member) else { continue }
            let saved = workspace.windows.filter {
                if let bundleIdentifier = $0.bundleIdentifier {
                    return bundleIdentifier == running.bundleIdentifier
                }
                return $0.appName == running.name
            }
            var matchedIDs = Set(
                running.windows
                    .filter { window in saved.contains { $0.title == window.title } }
                    .map(\.id)
            )
            if matchedIDs.isEmpty && saved.count == running.windows.count {
                matchedIDs.formUnion(running.windows.map(\.id))
            }
            selectedWindowIDs.formUnion(matchedIDs)
        }
    }

    private static func legacyApplications(from windows: [SavedWindowState]) -> [WorkspaceApplication] {
        var seen: Set<String> = []
        return windows.compactMap { window in
            let id = window.bundleIdentifier ?? window.appName
            guard seen.insert(id).inserted else { return nil }
            return WorkspaceApplication(
                name: window.appName,
                bundleIdentifier: window.bundleIdentifier,
                bundlePath: nil
            )
        }
    }
}

struct EndWorkSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var selected: Set<String> = []
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "power.circle.fill").font(.largeTitle).foregroundStyle(Color.foldeskRed)
                VStack(alignment: .leading) {
                    Text("安全结束工作").font(.title2.bold())
                    Text("选择要正常退出的应用").foregroundStyle(.secondary)
                }
            }
            List(state.applications) { app in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(app.id) },
                        set: { enabled in
                            if enabled { selected.insert(app.id) } else { selected.remove(app.id) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    AppIcon(image: app.icon, size: 26)
                    Text(app.name)
                    Spacer()
                    Text("\(app.windows.count) 个窗口").foregroundStyle(.secondary)
                    if ["Word", "Excel", "PowerPoint", "Photoshop"].contains(where: { app.name.contains($0) }) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 330)
            HStack {
                Button("全选") { selected = Set(state.applications.map(\.id)) }
                Button("取消") { state.showEndWork = false }
                Spacer()
                Button("退出 \(selected.count) 个应用", role: .destructive) { confirmed = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .alert("确认结束工作？", isPresented: $confirmed) {
            Button("返回检查", role: .cancel) {}
            Button("正常退出", role: .destructive) { state.quitApps(selected) }
        } message: {
            Text("Foldesk 会逐个发送正常退出请求。若存在未保存内容，原应用会继续询问你；Foldesk 自身始终保持运行。")
        }
    }
}

struct RecoveryOverlay: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.title2)
                .foregroundStyle(Color.foldeskBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("桌面已收起").font(.headline)
                Text("随时可以恢复刚才的工作状态").font(.caption).foregroundStyle(.secondary)
            }
            Button("恢复刚才") { state.restoreLatest() }
                .buttonStyle(.borderedProminent)
                .tint(Color.foldeskBlue)
            Button { state.showRecoveryOverlay = false } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
    }
}
