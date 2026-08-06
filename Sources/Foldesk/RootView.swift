import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 240)
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch state.selection {
                    case .applications: ApplicationsPage()
                    case .recent: RecentPage()
                    case .workspaces: WorkspacesPage()
                    case .splitLayout: SplitLayoutPage()
                    case .batch: BatchPage()
                    case .settings: SettingsPage()
                    }
                }
                if let toast = state.toast {
                    ToastView(text: toast)
                        .padding(.bottom, 74)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(2.2))
                            withAnimation { state.toast = nil }
                        }
                }
                if state.selection != .splitLayout {
                    BottomBar()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowZoomBehavior())
        .sheet(isPresented: $state.showEndWork) { EndWorkSheet() }
        .sheet(isPresented: $state.showNewWorkspace) {
            NewWorkspaceSheet(workspace: state.editingWorkspace)
        }
        .overlay(alignment: .bottomTrailing) {
            if state.showRecoveryOverlay {
                RecoveryOverlay()
                    .padding(.trailing, 24)
                    .padding(.bottom, 82)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusWindow)) { note in
            if let window = note.object as? WindowItem { state.manager.focus(window) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshPermissions()
            if state.accessibilityGranted { state.refresh() }
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            state.refreshPermissions()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: .foldeskBrandIcon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Foldesk").font(.system(size: 16, weight: .bold))
                    Text("窗口工作台").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            List(selection: $state.selection) {
                Section {
                    ForEach(SidebarItem.allCases) { item in
                        HStack {
                            Label(item.rawValue, systemImage: item.icon)
                            Spacer()
                        }
                        .font(.system(size: 14, weight: .medium))
                        .padding(.vertical, 5)
                        .tag(item)
                    }
                }

                Section("快捷操作") {
                    Button { state.foldAll() } label: {
                        Label("收起全部", systemImage: "arrow.down.to.line")
                    }
                    Button { state.restoreLatest() } label: {
                        Label("恢复刚才", systemImage: "arrow.uturn.backward")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Desktop"))
                    } label: {
                        Label("打开桌面", systemImage: "display")
                    }
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Circle().fill(Color.foldeskBlue).frame(width: 8, height: 8)
                    Text("Foldesk 1.0").font(.caption.weight(.medium))
                }
                Text("让窗口管理回归掌控")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.primary.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.panelBorder))
            .padding(16)
        }
    }
}

struct ApplicationsPage: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "窗口总控台",
                subtitle: "查看、收起、恢复和结束你的窗口工作区",
                searchable: true
            )
            PermissionBanner()

            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        HStack {
                            Circle().fill(Color.foldeskBlue).frame(width: 8, height: 8)
                            Text("\(state.applications.count) 个应用  ·  \(state.windowCount) 个窗口  ·  当前已选 \(state.selectedWindowIDs.count) 项")
                                .font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            Text("更新于 \(state.lastRefresh.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Color.primary.opacity(0.018))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.panelBorder))
                        .clipShape(RoundedRectangle(cornerRadius: 9))

                        if state.filteredApplications.isEmpty {
                            EmptyState(symbol: "rectangle.on.rectangle.slash", title: "没有找到窗口", message: "换一个关键词，或刷新当前应用列表。")
                                .frame(height: 320)
                        } else {
                            ForEach(state.filteredApplications) { app in
                                ApplicationCard(app: app)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 88)
                }
                QuickInspector()
                    .frame(width: 230)
                    .padding(.trailing, 20)
            }
        }
    }
}

struct PageHeader: View {
    @EnvironmentObject private var state: AppState
    let title: String
    let subtitle: String
    var searchable = false

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text(title).font(.system(size: 28, weight: .bold))
                    Text("Mac App")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.foldeskBlue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.foldeskBlue.opacity(0.08))
                        .clipShape(Capsule())
                }
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if searchable {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索应用、窗口或文件名", text: $state.searchText)
                        .textFieldStyle(.plain)
                    if !state.searchText.isEmpty {
                        Button { state.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(width: 270, height: 34)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.panelBorder))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Button { state.refresh() } label: {
                    Image(systemName: state.isRefreshing ? "arrow.clockwise.circle.fill" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新窗口")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }
}

struct PermissionBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if !state.accessibilityGranted || !state.screenRecordingGranted {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permissionTitle)
                        .font(.caption.weight(.semibold))
                    Text(permissionDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新检测") {
                    state.refreshPermissions()
                    if state.accessibilityGranted { state.refresh() }
                }
                .controlSize(.small)
                if !state.accessibilityGranted {
                    Button("开启辅助功能") { state.requestAccessibilityPermission() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if !state.screenRecordingGranted {
                    Button("开启屏幕录制") { state.requestScreenRecordingPermission() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color.orange.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.orange.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }

    private var permissionTitle: String {
        if !state.accessibilityGranted && !state.screenRecordingGranted { return "需要两项系统权限" }
        if !state.accessibilityGranted { return "未检测到辅助功能授权" }
        return "未检测到屏幕录制授权"
    }

    private var permissionDetail: String {
        if !state.accessibilityGranted && !state.screenRecordingGranted {
            return "辅助功能用于控制窗口，屏幕录制仅用于本机生成窗口缩略图。"
        }
        if !state.accessibilityGranted { return "窗口控制暂不可用，请为当前版本重新授权。" }
        return "窗口控制可用；授权屏幕录制后显示真实窗口缩略图。"
    }
}

struct ApplicationCard: View {
    @EnvironmentObject private var state: AppState
    let app: RunningAppItem
    @State private var expanded = true
    @State private var confirmQuit = false

    private var isRisky: Bool {
        ["Word", "Excel", "PowerPoint", "Photoshop", "Pages", "Numbers"].contains { app.name.localizedCaseInsensitiveContains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.foldeskBlue)
                }
                .buttonStyle(.plain)
                AppIcon(image: app.icon)
                Text(app.name).font(.system(size: 15, weight: .semibold))
                Text("\(app.windows.count) 个窗口").font(.caption).foregroundStyle(.secondary)
                if isRisky {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("此应用可能包含未保存内容")
                }
                Spacer()
                Button { state.manager.show(app) } label: {
                    Label("显示全部", systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(role: .destructive) { confirmQuit = true } label: {
                    Label("退出应用", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Menu {
                    Button("收起应用", systemImage: "arrow.down.to.line") { state.manager.hide(app) }
                    Button("最小化全部窗口", systemImage: "minus") { state.manager.minimizeAll(app) }
                    Button("关闭全部窗口（应用仍运行）", systemImage: "xmark") { state.manager.closeAll(app) }
                    Divider()
                    Button("退出应用", systemImage: "power", role: .destructive) { confirmQuit = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 25, height: 22)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 13)
            .frame(height: 48)

            if expanded {
                Divider().opacity(0.5)
                if app.windows.isEmpty {
                    HStack {
                        Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                        Text("应用正在后台运行，暂无可管理窗口。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("激活应用") { state.manager.show(app) }
                            .buttonStyle(.link)
                    }
                    .padding(14)
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 10) {
                                ForEach(app.windows) { window in
                                    WindowThumbnail(
                                        window: window,
                                        icon: app.icon,
                                        selected: state.selectedWindowIDs.contains(window.id)
                                    ) {
                                        state.toggleSelected(window)
                                    }
                                    .contextMenu {
                                        Button("切换到窗口") { state.manager.focus(window) }
                                        Button("最小化窗口") { state.manager.minimize(window) }
                                        Button("放大或全屏") { state.manager.toggleZoom(window) }
                                        Button("关闭窗口（应用仍运行）", role: .destructive) { state.manager.close(window) }
                                    }
                                    .frame(width: 138)
                                }
                            }
                        }
                        .frame(minWidth: 200)
                        Divider().frame(height: 84)
                        VStack(spacing: 7) {
                            ActionButton(title: "收起应用", symbol: "arrow.down.to.line") { state.manager.hide(app) }
                            ActionButton(title: "最小化全部", symbol: "minus") { state.manager.minimizeAll(app) }
                            ActionButton(title: "退出应用", symbol: "power", role: .destructive) { confirmQuit = true }
                        }
                        .frame(width: 112)
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .alert("退出 \(app.name)？", isPresented: $confirmQuit) {
            Button("取消", role: .cancel) {}
            Button("正常退出", role: .destructive) { state.quitApplication(app) }
        } message: {
            Text(isRisky ? "应用可能包含未保存内容。Foldesk 会发送正常退出请求，由原应用继续处理保存确认。" : "Foldesk 会发送正常退出请求，不会强制结束进程。")
        }
    }
}

struct QuickInspector: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Label("一键回到桌面", systemImage: "display")
                    .font(.headline)
                    .foregroundStyle(Color.foldeskBlue)
                ActionButton(title: "收起全部", symbol: "arrow.down.to.line", prominent: true) { state.foldAll() }
                ActionButton(title: "恢复刚才", symbol: "arrow.uturn.backward") { state.restoreLatest() }
                Text("记录当前窗口状态，临时隐藏所有应用，再次点击即可恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.panelBorder))
            .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 12) {
                Label("结束工作", systemImage: "power.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.foldeskRed)
                Text("安全退出选中的应用，遇到未保存内容时交还原应用确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    state.showEndWork = true
                } label: {
                    Text("选择要退出的应用")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.panelBorder))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            Spacer()
        }
    }
}

struct BottomBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Button { state.foldAll() } label: {
                Label("收起全部", systemImage: "arrow.down.to.line").frame(width: 135)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.foldeskBlue)
            Button { state.restoreLatest() } label: {
                Label("恢复刚才", systemImage: "arrow.uturn.backward").frame(width: 135)
            }
            Button { state.showEndWork = true } label: {
                Label("结束工作", systemImage: "power").frame(width: 135)
            }
            Button { state.beginCreatingWorkspace() } label: {
                Label("新建工作区", systemImage: "folder.badge.plus").frame(width: 135)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(8)
        .background(.regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 7)
        .padding(.bottom, 14)
    }
}
