import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selection: SidebarItem = .applications
    @Published var applications: [RunningAppItem] = []
    @Published var searchText = ""
    @Published var selectedWindowIDs: Set<String> = []
    @Published var records: [FoldRecord] = []
    @Published var workspaces: [WorkspaceItem] = []
    @Published var preferences = AppPreferences()
    @Published var isRefreshing = false
    @Published var lastRefresh = Date()
    @Published var toast: String?
    @Published var showEndWork = false
    @Published var showNewWorkspace = false
    @Published var editingWorkspace: WorkspaceItem?
    @Published var showRecoveryOverlay = false
    @Published var accessibilityGranted = false
    @Published var screenRecordingGranted = false
    @Published private(set) var activeWorkspaceIDs: [UUID] = []
    /// 统一浮窗中的工作区 Tab 顺序
    @Published private(set) var floatingTabIDs: [UUID] = []
    /// 当前浮窗中选中的工作区 Tab
    @Published var selectedFloatingWorkspaceID: UUID?
    @Published private(set) var visibleFloatingWorkspaceIDs: Set<UUID> = []
    /// 已从总控制台拖出的独立工作区窗口。
    @Published private(set) var detachedWorkspaceIDs: Set<UUID> = []
    @Published private(set) var workspaceLayoutFeedback: [UUID: String] = [:]

    // 全局唤起快捷键
    @Published var isRecording = false
    @Published var summonKeyCode: Int = -1          // -1 = 未设置
    @Published var summonModifiers: UInt = 0
    @Published var summonKeyLabel: String = ""

    private var globalToken: Any?
    private var localToken: Any?
    private var workspaceObserverTokens: [Any] = []
    private var preparedWorkspaceMemberIDs: [UUID: Set<String>] = [:]
    /// 单一统一浮窗控制器（管理所有活跃工作区 Tab）
    private var unifiedFloatingController: WorkspaceFloatingPanelController?
    /// 独立窗口需要由状态层强持有，否则拖出后会立即释放。
    private var detachedWorkspaceControllers: [UUID: DetachedWorkspacePanelController] = [:]

    let manager = WindowManager()
    private let recordsKey = "foldesk.records.v1"
    private let workspacesKey = "foldesk.workspaces.v1"
    private let preferencesKey = "foldesk.preferences.v1"
    private let activeWorkspaceKey = "foldesk.activeWorkspaces.v1"

    private init() {
        load()
        refreshPermissions()
        refresh()
        registerHotkey()
        registerWorkspaceObservers()
    }

    var filteredApplications: [RunningAppItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applications }
        return applications.compactMap { app in
            if app.name.localizedCaseInsensitiveContains(query) { return app }
            let matches = app.windows.filter { $0.title.localizedCaseInsensitiveContains(query) }
            guard !matches.isEmpty else { return nil }
            var copy = app
            copy.windows = matches
            return copy
        }
    }

    var windowCount: Int { applications.reduce(0) { $0 + $1.windows.count } }
    var latestRecord: FoldRecord? { records.first }

    func refresh() {
        refreshPermissions()
        isRefreshing = true
        applications = manager.scanApplications()
        lastRefresh = Date()
        isRefreshing = false
    }

    func refreshPermissions() {
        accessibilityGranted = manager.hasAccessibilityPermission
        screenRecordingGranted = manager.hasScreenRecordingPermission
    }

    func requestAccessibilityPermission() {
        manager.requestAccessibilityPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.refreshPermissions()
        }
    }

    func requestScreenRecordingPermission() {
        let granted = manager.requestScreenRecordingPermission()
        refreshPermissions()
        if granted && !screenRecordingGranted {
            toast = "屏幕录制已开启，重新启动 Foldesk 后生效"
        }
    }

    func manageAccessibilityPermission() {
        manager.openAccessibilitySettings()
    }

    func manageScreenRecordingPermission() {
        manager.openScreenRecordingSettings()
    }

    /// 注册系统级应用生命周期监听，确保槽位 UI 与真实世界同步。
    private func registerWorkspaceObservers() {
        let workspace = NSWorkspace.shared
        let center = NotificationCenter.default

        // 应用退出 → 刷新列表 + 清理该工作区的过期反馈
        let quitToken = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bundleID = app.bundleIdentifier ?? ""
            let localizedName = app.localizedName
            // 回到主 actor 上操作状态，避免并发隔离告警
            Task { @MainActor in
                // 检查是否有活跃工作区包含这个应用
                for ws in self.activeWorkspaces {
                    let hasMember = ws.memberApplications.contains { member in
                        member.bundleIdentifier == bundleID || member.name == localizedName
                    }
                    if hasMember {
                        self.refresh()
                        // 清理反馈，让用户看到最新状态
                        if self.workspaceLayoutFeedback[ws.id] != nil {
                            self.workspaceLayoutFeedback.removeValue(forKey: ws.id)
                        }
                        break
                    }
                }
            }
        }
        workspaceObserverTokens.append(quitToken)

        // 应用启动 → 刷新列表（让槽位状态从"未运行"变为"已打开"）
        let launchToken = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bundleID = app.bundleIdentifier ?? ""
            let localizedName = app.localizedName
            Task { @MainActor in
                for ws in self.activeWorkspaces {
                    let hasMember = ws.memberApplications.contains { member in
                        member.bundleIdentifier == bundleID || member.name == localizedName
                    }
                    if hasMember {
                        // 等待应用窗口就绪后再补排
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        self.refresh()
                        // 如果有分屏配置，自动尝试补排新启动的应用
                        if ws.slotAssignments != nil {
                            let assignedMembers = ws.memberApplications.filter { ws.slotAssignments?[$0.id] != nil }
                            let placed = self.applyWorkspaceLayout(ws)
                            self.updateWorkspaceLayoutFeedback(
                                workspace: ws,
                                assignedMembers: assignedMembers,
                                placed: placed,
                                totalSlots: assignedMembers.count
                            )
                        }
                        break
                    }
                }
            }
        }
        workspaceObserverTokens.append(launchToken)
    }

    // MARK: - 全局唤起快捷键
    /// 注册全局 + 本地键盘监听。全局监听负责在 App 处于后台时唤起主窗口；
    /// 本地监听在「录制」状态下捕获下一个按键组合。
    func registerHotkey() {
        if let t = globalToken { NSEvent.removeMonitor(t) }
        if let t = localToken { NSEvent.removeMonitor(t) }
        globalToken = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event)
        }
        localToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if isRecording { captureShortcut(from: event); return nil }
            return event
        }
    }

    private func handleHotkey(_ event: NSEvent) {
        guard !isRecording, summonKeyCode >= 0 else { return }
        let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let mods = event.modifierFlags.intersection(mask)
        let stored = NSEvent.ModifierFlags(rawValue: summonModifiers)
        guard mods == stored, Int(event.keyCode) == summonKeyCode else { return }
        summonApp()
    }

    /// 把 Foldesk 主窗口提到最前（后台也能唤出）。
    func summonApp() {
        MainWindowController.shared.show(state: self)
    }

    func startRecording() { isRecording = true }
    func cancelRecording() { isRecording = false }

    func clearSummonShortcut() {
        summonKeyCode = -1
        summonModifiers = 0
        summonKeyLabel = ""
        savePreferences()
    }

    private func captureShortcut(from event: NSEvent) {
        let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let mods = event.modifierFlags.intersection(mask)
        // 功能键（F1–F12）允许单独使用，普通键必须带修饰键，避免劫持正常输入
        let funcKeys = Set([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111])
        guard !mods.isEmpty || funcKeys.contains(Int(event.keyCode)) else {
            toast = "请同时按住 ⌘ / ⌥ / ⌃ / ⇧，或单独按 F 功能键"
            return
        }
        summonModifiers = mods.rawValue
        summonKeyCode = Int(event.keyCode)
        let label = (event.charactersIgnoringModifiers ?? "").uppercased()
        summonKeyLabel = label.isEmpty ? keyName(for: summonKeyCode) : label
        isRecording = false
        savePreferences()
        toast = "已设置唤起快捷键：\(summonShortcutDescription)"
    }

    var summonShortcutDescription: String {
        guard summonKeyCode >= 0 else { return "未设置" }
        let mods = NSEvent.ModifierFlags(rawValue: summonModifiers)
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s + (summonKeyLabel.isEmpty ? keyName(for: summonKeyCode) : summonKeyLabel)
    }

    private func keyName(for code: Int) -> String {
        switch code {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "Tab"
        case 51: return "⌫"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"; case 120: return "F2"; case 99: return "F3"; case 118: return "F4"
        case 96: return "F5"; case 97: return "F6"; case 98: return "F7"; case 100: return "F8"
        case 101: return "F9"; case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        default: return "键\(code)"
        }
    }

    func foldAll() {
        foldAll(ensureDesktopIsClear: false)
    }

    private func foldAll(ensureDesktopIsClear: Bool) {
        // 1. 先按排除列表筛出真正会被折叠的应用
        let foldableApps = applications.filter { app in
            guard let bid = app.bundleIdentifier else { return true }
            return !preferences.excludedBundleIDs.contains(bid)
        }

        // 2. 全被排除时直接告诉用户，不弹浮层
        guard !foldableApps.isEmpty else {
            toast = "所有应用都在排除列表，无法收起。请在设置 → 排除应用中调整。"
            return
        }

        // 3. 只统计实际会折叠的窗口
        let states = foldableApps.flatMap { $0.windows.compactMap(savedState(for:)) }
        let excludedWindowCount = windowCount - states.count

        guard !states.isEmpty else {
            toast = "当前没有可收起的窗口"
            return
        }

        if preferences.saveHistory {
            let record = FoldRecord(
                id: UUID(),
                name: "桌面快照 \(records.count + 1)",
                date: Date(),
                windows: states,
                restored: false
            )
            records.insert(record, at: 0)
            records = Array(records.prefix(10))
            save()
        }

        for app in foldableApps {
            switch preferences.foldMode {
            case .hide:
                manager.hide(app)
            case .minimize:
                manager.minimizeAll(app)
            case .mixed:
                app.windows.count > 1 ? manager.hide(app) : manager.minimizeAll(app)
            }
        }

        // 4. 浮层只在确实收起了东西时弹；有排除时附带括号说明
        showRecoveryOverlay = preferences.showRecoveryOverlay && !states.isEmpty
        if excludedWindowCount > 0 {
            toast = "已收起 \(states.count) 个窗口（另有 \(excludedWindowCount) 个被排除）"
        } else {
            toast = "已收起 \(states.count) 个窗口"
        }
        if ensureDesktopIsClear {
            // NSRunningApplication.hide() 对部分 Electron / 自定义窗口应用可能“返回成功”
            // 但窗口仍留在桌面。等隐藏动画结束后复查，只最小化仍在屏幕上的窗口。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.manager.minimizeWindowsStillOnScreen(in: foldableApps)
                self.refresh()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.refresh()
            }
        }
    }

    func returnToDesktop() {
        foldAll(ensureDesktopIsClear: true)
        MainWindowController.shared.minimize()
    }

    func restoreLatest() {
        guard let record = records.first else {
            toast = "还没有可恢复的收起记录"
            return
        }
        restore(record)
    }

    func restore(_ record: FoldRecord) {
        refresh()
        manager.restore(record.windows, applications: applications, preferences: preferences)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index].restored = true
        }
        showRecoveryOverlay = false
        toast = "正在恢复 \(record.windows.count) 个窗口"
        save()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
    }

    func saveCurrentWorkspace(
        name: String,
        symbol: String = "briefcase.fill",
        workspaceApplications: [WorkspaceApplication],
        selectedWindowIDs: Set<String>,
        editingWorkspaceID: UUID? = nil
    ) {
        let memberIDs = Set(workspaceApplications.map(\.id))
        let runningMemberIDs = Set(applications.compactMap { app -> String? in
            let id = app.bundleIdentifier ?? app.bundleURL?.path ?? app.name
            return memberIDs.contains(id) ? id : nil
        })
        let selectedWindows = applications
            .flatMap(\.windows)
            .filter { window in
                guard selectedWindowIDs.contains(window.id),
                      let app = applications.first(where: { $0.pid == window.pid }) else { return false }
                let id = app.bundleIdentifier ?? app.bundleURL?.path ?? app.name
                return memberIDs.contains(id)
            }
        let existing = editingWorkspaceID.flatMap { id in
            workspaces.first { $0.id == id }
        }
        let preservedWindows = existing?.windows.filter { window in
            let id = window.bundleIdentifier ?? window.appName
            return memberIDs.contains(id) && !runningMemberIDs.contains(id)
        } ?? []
        let savedWindows = selectedWindows.compactMap(savedState(for:)) + preservedWindows
        let item = WorkspaceItem(
            id: existing?.id ?? UUID(),
            name: name.isEmpty ? "新工作区" : name,
            symbol: symbol,
            colorName: existing?.colorName ?? ["blue", "purple", "orange", "green"][workspaces.count % 4],
            createdAt: existing?.createdAt ?? Date(),
            windows: savedWindows,
            applications: workspaceApplications,
            autoLaunchApplicationIDs: existing?.autoLaunchApplicationIDs,
            layoutKind: existing?.layoutKind,
            slotAssignments: existing?.slotAssignments
        )
        if let index = workspaces.firstIndex(where: { $0.id == item.id }) {
            workspaces[index] = item
        } else {
            workspaces.append(item)
        }
        showNewWorkspace = false
        editingWorkspace = nil
        toast = existing == nil
            ? "“\(item.name)”已保存 \(memberIDs.count) 个应用、\(item.windows.count) 个窗口"
            : "“\(item.name)”已更新"
        save()
    }

    func beginCreatingWorkspace() {
        editingWorkspace = nil
        showNewWorkspace = true
    }

    func beginEditingWorkspace(_ workspace: WorkspaceItem) {
        editingWorkspace = workspace
        showNewWorkspace = true
    }

    func cancelWorkspaceEditor() {
        showNewWorkspace = false
        editingWorkspace = nil
    }

    func openWorkspace(_ workspace: WorkspaceItem) {
        if activeWorkspaceIDs.contains(workspace.id) {
            if preferences.showFloatingConsole {
                showFloatingWorkspacePanel(for: workspace.id)
            }
            toast = "“\(workspace.name)”已经打开"
            return
        }
        guard activeWorkspaceIDs.count < 3 else {
            toast = "最多同时打开 3 个工作区，请先结束一个"
            return
        }

        refresh()
        let members = workspace.memberApplications
        let autoLaunchMembers = members.filter { workspace.autoLaunchIDs.contains($0.id) }
        let allOpenMembers = activeWorkspaces.flatMap(\.memberApplications) + members
        foldApplicationsUnrelated(to: allOpenMembers)
        activeWorkspaceIDs.append(workspace.id)
        preparedWorkspaceMemberIDs[workspace.id] = []

        for member in autoLaunchMembers {
            if applications.contains(where: {
                if let bundleIdentifier = member.bundleIdentifier {
                    return $0.bundleIdentifier == bundleIdentifier
                }
                return $0.name == member.name
            }) {
                continue
            }

            launchWorkspaceMember(member)
        }

        toast = "已进入“\(workspace.name)” · 已选择 \(activeWorkspaceIDs.count) 个工作区"
        if !autoLaunchMembers.isEmpty {
            for delay in [0.8, 2.5, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.activateWorkspaceMembers(
                        autoLaunchMembers,
                        workspace: workspace,
                        reportToast: false
                    )
                }
            }
        }
        if preferences.showFloatingConsole {
            showFloatingWorkspacePanel(for: workspace.id)
        }
    }

    private func activateWorkspaceMembers(
        _ members: [WorkspaceApplication],
        workspace: WorkspaceItem,
        force: Bool = false,
        reportToast: Bool = true
    ) {
        guard activeWorkspaceIDs.contains(workspace.id) else { return }
        refresh()
        let memberIDs = Set(members.map(\.id))
        let runningMembers = applications.filter { app in
            if let bundleIdentifier = app.bundleIdentifier {
                return memberIDs.contains(bundleIdentifier)
            }
            return members.contains { $0.name == app.name }
        }
        let preparedIDs = preparedWorkspaceMemberIDs[workspace.id] ?? []
        let membersToPrepare = force
            ? runningMembers
            : runningMembers.filter { !preparedIDs.contains(workspaceMemberID(for: $0)) }

        for app in membersToPrepare {
            let savedForApp = workspace.windows.filter {
                if let bundleIdentifier = $0.bundleIdentifier {
                    return bundleIdentifier == app.bundleIdentifier
                }
                return $0.appName == app.name
            }
            let isSharedWithAnotherOpenWorkspace = activeWorkspaces
                .filter { $0.id != workspace.id }
                .contains { other in
                    workspaceMembers(other.memberApplications, contain: app)
                }
            manager.show(app)
            if !savedForApp.isEmpty && !isSharedWithAnotherOpenWorkspace {
                for window in app.windows where !savedForApp.contains(where: { $0.title == window.title }) {
                    manager.minimize(window)
                }
            }
        }
        var workspacePreferences = preferences
        workspacePreferences.rememberPosition = true
        workspacePreferences.rememberSize = true
        manager.restore(
            workspace.windows,
            applications: membersToPrepare,
            preferences: workspacePreferences,
            restoreMinimizedState: false
        )
        let memberIDsToPlace = Set(members.compactMap { member in
            membersToPrepare.contains { app in
                workspaceMembers([member], contain: app)
            } ? member.id : nil
        })
        applyWorkspaceLayout(
            workspace,
            restrictingTo: memberIDsToPlace
        )
        for app in membersToPrepare {
            let savedForApp = workspace.windows.filter {
                if let bundleIdentifier = $0.bundleIdentifier {
                    return bundleIdentifier == app.bundleIdentifier
                }
                return $0.appName == app.name
            }
            if savedForApp.isEmpty || !app.windows.isEmpty {
                preparedWorkspaceMemberIDs[workspace.id, default: []]
                    .insert(workspaceMemberID(for: app))
            }
        }
        let restoredWindows = workspace.windows.filter { saved in
            runningMembers.contains { app in
                let sameApp = saved.bundleIdentifier.map { $0 == app.bundleIdentifier } ?? (saved.appName == app.name)
                return sameApp && app.windows.contains { $0.title == saved.title }
            }
        }.count
        if reportToast {
            toast = "“\(workspace.name)”：应用 \(runningMembers.count)/\(members.count) · 窗口 \(restoredWindows)/\(workspace.windows.count)"
        }
    }

    var activeWorkspaces: [WorkspaceItem] {
        activeWorkspaceIDs.compactMap { id in workspaces.first { $0.id == id } }
    }

    func workspace(withID id: UUID) -> WorkspaceItem? {
        workspaces.first { $0.id == id }
    }

    func isWorkspaceActive(_ id: UUID) -> Bool {
        activeWorkspaceIDs.contains(id)
    }

    func reapplyWorkspace(_ workspace: WorkspaceItem) {
        let members = workspace.applications ?? legacyApplications(for: workspace)
        activateWorkspaceMembers(members, workspace: workspace, force: true)
    }

    func runningApplication(for member: WorkspaceApplication) -> RunningAppItem? {
        applications.first {
            if let bundleIdentifier = member.bundleIdentifier {
                return bundleIdentifier == $0.bundleIdentifier
            }
            if let bundlePath = member.bundlePath {
                return bundlePath == $0.bundleURL?.path
            }
            return member.name == $0.name
        }
    }

    func windows(in workspace: WorkspaceItem, for member: WorkspaceApplication) -> [WindowItem] {
        guard let app = runningApplication(for: member) else { return [] }
        let saved = workspace.windows.filter {
            if let bundleIdentifier = $0.bundleIdentifier {
                return bundleIdentifier == app.bundleIdentifier
            }
            return $0.appName == app.name
        }
        guard !saved.isEmpty else { return app.windows }
        let matching = app.windows.filter { window in
            saved.contains { $0.title == window.title }
        }
        if matching.isEmpty && saved.count == app.windows.count {
            return app.windows
        }
        return matching
    }

    func showWorkspaceMember(_ member: WorkspaceApplication, in workspaceID: UUID? = nil) {
        refresh()
        if let app = runningApplication(for: member) {
            manager.show(app)
            if let workspaceID,
               activeWorkspaceIDs.contains(workspaceID),
               let workspace = workspace(withID: workspaceID) {
                applyWorkspaceLayout(workspace, restrictingTo: [member.id])
            }
            toast = "已显示 \(member.name)"
            return
        }
        launchWorkspaceMember(member)
        toast = "正在打开 \(member.name)"
        if let workspaceID,
           activeWorkspaceIDs.contains(workspaceID),
           let workspace = workspace(withID: workspaceID) {
            for delay in [0.7, 1.8, 3.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.activateWorkspaceMembers(
                        [member],
                        workspace: workspace,
                        force: true,
                        reportToast: false
                    )
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.refresh() }
        }
    }

    func openAllWorkspaceMembers(in workspaceID: UUID) {
        guard activeWorkspaceIDs.contains(workspaceID),
              let workspace = workspace(withID: workspaceID) else {
            toast = "请先进入一个工作区"
            return
        }
        refresh()
        for member in workspace.memberApplications where runningApplication(for: member) == nil {
            launchWorkspaceMember(member)
        }
        preparedWorkspaceMemberIDs[workspace.id] = []
        for delay in [0.8, 2.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.activateWorkspaceMembers(
                    workspace.memberApplications,
                    workspace: workspace,
                    reportToast: false
                )
            }
        }
        toast = "正在打开“\(workspace.name)”的全部成员应用"
    }

    func applyActiveWorkspaceLayout(in workspaceID: UUID) {
        // ① 权限校验——没权限就直接告诉用户，不假装分屏
        guard accessibilityGranted else {
            setWorkspaceLayoutFeedback("无法分屏：请先在系统设置中开启辅助功能权限", for: workspaceID)
            manageAccessibilityPermission()
            return
        }

        guard activeWorkspaceIDs.contains(workspaceID),
              let workspace = workspace(withID: workspaceID) else {
            setWorkspaceLayoutFeedback("请先进入一个工作区", for: workspaceID)
            return
        }
        guard let assignments = workspace.slotAssignments, !assignments.isEmpty else {
            setWorkspaceLayoutFeedback("请先为分屏槽位选择应用（点击槽位分配）", for: workspaceID)
            return
        }

        refresh()
        let assignedMembers = workspace.memberApplications.filter {
            assignments[$0.id] != nil
        }
        guard !assignedMembers.isEmpty else {
            setWorkspaceLayoutFeedback("请先为分屏槽位选择应用（点击槽位分配）", for: workspaceID)
            return
        }

        // ② 逐个处理：未运行→启动并等窗口；运行但无窗→激活并等窗口
        let totalSlots = assignedMembers.count
        var pendingMembers: [WorkspaceApplication] = []

        for member in assignedMembers {
            if runningApplication(for: member) == nil {
                launchWorkspaceMember(member)
                pendingMembers.append(member)
            } else if let app = runningApplication(for: member), app.windows.isEmpty {
                // 进程在但没窗口，尝试重新打开
                launchWorkspaceMember(member)
                pendingMembers.append(member)
            }
        }

        if !pendingMembers.isEmpty {
            setWorkspaceLayoutFeedback(
                "正在启动 \(pendingMembers.map(\.name).joined(separator: "、"))…",
                for: workspaceID
            )
        }

        // ③ 先对已经出现的窗口执行一次摆位。不能在主线程同步等待窗口，
        // 否则等待回调也在主线程时会互相阻塞。
        refresh()
        let placed = applyWorkspaceLayout(workspace)

        // ④ 基于真实结果给反馈
        updateWorkspaceLayoutFeedback(
            workspace: workspace,
            assignedMembers: assignedMembers,
            placed: placed,
            totalSlots: totalSlots
        )

        // ⑤ 只有确实在等待新窗口时才异步补排。已经就位的窗口会被
        // isWindowNearRect 跳过，不再重复缩放或置前。
        if placed < totalSlots, !pendingMembers.isEmpty {
            for delay in [0.6, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.activeWorkspaceIDs.contains(workspace.id),
                          let ws = self.workspace(withID: workspace.id),
                          let currentAssignments = ws.slotAssignments else { return }
                    self.refresh()
                    let retryMembers = ws.memberApplications.filter {
                        currentAssignments[$0.id] != nil
                    }
                    let retryPlaced = self.applyWorkspaceLayout(ws)
                    self.updateWorkspaceLayoutFeedback(
                        workspace: ws,
                        assignedMembers: retryMembers,
                        placed: retryPlaced,
                        totalSlots: retryMembers.count
                    )
                }
            }
        }
    }

    private func setWorkspaceLayoutFeedback(_ message: String, for workspaceID: UUID) {
        workspaceLayoutFeedback[workspaceID] = message
        toast = message
    }

    private func updateWorkspaceLayoutFeedback(
        workspace: WorkspaceItem,
        assignedMembers: [WorkspaceApplication],
        placed: Int,
        totalSlots: Int? = nil
    ) {
        let total = totalSlots ?? assignedMembers.count
        let message: String
        if !accessibilityGranted {
            message = "无法分屏：请先在系统设置中开启辅助功能权限"
        } else if placed == total && total > 0 {
            message = "已排列 \(placed)/\(total) 个窗口 ✓"
        } else if placed > 0 {
            let failedNames = assignedMembers.compactMap { member -> String? in
                guard runningApplication(for: member) == nil else { return nil }
                return member.name
            }
            let noWindowNames = assignedMembers.compactMap { member -> String? in
                guard runningApplication(for: member) != nil else { return nil }
                return windows(in: workspace, for: member).isEmpty ? member.name : nil
            }
            if !failedNames.isEmpty {
                message = "已排列 \(placed)/\(total)；\(failedNames.joined(separator: "、")) 未运行"
            } else if !noWindowNames.isEmpty {
                message = "已排列 \(placed)/\(total)；\(noWindowNames.joined(separator: "、")) 无可用窗口"
            } else {
                message = "已排列 \(placed)/\(total)；部分窗口可能不支持调整大小"
            }
        } else if total > 0 {
            let notRunning = assignedMembers.filter { runningApplication(for: $0) == nil }.map(\.name)
            if !notRunning.isEmpty {
                message = "分屏失败：\(notRunning.joined(separator: "、")) 无法启动"
            } else {
                message = "分屏失败：请确认目标窗口允许调整大小"
            }
        } else {
            message = "没有可分屏的应用"
        }
        setWorkspaceLayoutFeedback(message, for: workspace.id)
    }

    func setWorkspaceAutoLaunch(
        _ enabled: Bool,
        member: WorkspaceApplication,
        workspaceID: UUID
    ) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        var ids = workspaces[index].autoLaunchIDs
        if enabled { ids.insert(member.id) } else { ids.remove(member.id) }
        workspaces[index].autoLaunchApplicationIDs = ids
        save()
    }

    func setWorkspaceLayout(_ kind: WorkspaceLayoutKind, workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].layoutKind = kind
        let validSlots = kind.regions.indices
        workspaces[index].slotAssignments = workspaces[index].slotAssignments?
            .filter { validSlots.contains($0.value) }
        save()
        if activeWorkspaceIDs.contains(workspaceID),
           !(workspaces[index].slotAssignments?.isEmpty ?? true) {
            applyActiveWorkspaceLayout(in: workspaceID)
        }
    }

    func assignWorkspaceMember(
        _ member: WorkspaceApplication?,
        to slot: Int,
        workspaceID: UUID
    ) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        var assignments = workspaces[index].slotAssignments ?? [:]
        assignments = assignments.filter { $0.value != slot }
        if let member {
            assignments[member.id] = slot
        }
        workspaces[index].slotAssignments = assignments
        save()
        if member != nil, activeWorkspaceIDs.contains(workspaceID) {
            applyActiveWorkspaceLayout(in: workspaceID)
        }
    }

    func addApplication(_ url: URL, toWorkspace workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let bundle = Bundle(url: url)
        let name =
            bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
            bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ??
            url.deletingPathExtension().lastPathComponent
        let member = WorkspaceApplication(
            name: name,
            bundleIdentifier: bundle?.bundleIdentifier,
            bundlePath: url.path
        )
        var members = workspaces[index].memberApplications
        guard !members.contains(where: { $0.id == member.id }) else {
            toast = "\(name) 已在工作区中"
            return
        }
        members.append(member)
        workspaces[index].applications = members
        save()
        toast = "已将 \(name) 加入工作区，默认按需打开"
    }

    func removeWorkspaceMember(_ member: WorkspaceApplication, workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].applications = workspaces[index].memberApplications.filter { $0.id != member.id }
        workspaces[index].autoLaunchApplicationIDs?.remove(member.id)
        workspaces[index].slotAssignments?.removeValue(forKey: member.id)
        workspaces[index].windows.removeAll {
            if let bundleIdentifier = member.bundleIdentifier {
                return $0.bundleIdentifier == bundleIdentifier
            }
            return $0.appName == member.name
        }
        save()
        toast = "已从工作区移除 \(member.name)，不会退出或卸载应用"
    }

    func minimizeWorkspaceMember(_ member: WorkspaceApplication) {
        refresh()
        guard let app = runningApplication(for: member) else {
            toast = "\(member.name) 尚未运行"
            return
        }
        manager.minimizeAll(app)
        toast = "已最小化 \(member.name)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    func zoomWorkspaceMember(_ member: WorkspaceApplication) {
        refresh()
        guard let app = runningApplication(for: member) else {
            toast = "\(member.name) 尚未运行"
            return
        }
        app.windows.forEach(manager.toggleZoom)
        toast = "已放大或还原 \(member.name) 的窗口"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    func closeWorkspaceMemberWindows(_ member: WorkspaceApplication) {
        refresh()
        guard let app = runningApplication(for: member) else {
            toast = "\(member.name) 尚未运行"
            return
        }
        manager.closeAll(app)
        toast = "已关闭 \(member.name) 的窗口，应用可能仍在运行"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refresh() }
    }

    func quitWorkspaceMember(_ member: WorkspaceApplication) {
        refresh()
        guard let app = runningApplication(for: member) else {
            toast = "\(member.name) 尚未运行"
            return
        }
        quitApplication(app)
    }

    func focusWorkspaceWindow(_ window: WindowItem) {
        manager.focus(window)
    }

    func minimizeWorkspaceWindow(_ window: WindowItem) {
        manager.minimize(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    func zoomWorkspaceWindow(_ window: WindowItem) {
        manager.toggleZoom(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    func closeWorkspaceWindow(_ window: WindowItem) {
        manager.close(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refresh() }
    }

    func isFloatingWorkspaceVisible(_ workspaceID: UUID) -> Bool {
        floatingTabIDs.contains(workspaceID) || detachedWorkspaceIDs.contains(workspaceID)
    }

    func showFloatingConsole() {
        if unifiedFloatingController == nil {
            unifiedFloatingController = WorkspaceFloatingPanelController(state: self)
        }
        unifiedFloatingController?.show()
    }

    func setFloatingConsoleVisibility(_ isVisible: Bool) {
        preferences.showFloatingConsole = isVisible
        savePreferences()
        if isVisible {
            showFloatingConsole()
        } else {
            unifiedFloatingController?.dispose()
            unifiedFloatingController = nil
        }
    }

    func toggleFloatingWorkspacePanel(for workspaceID: UUID) {
        guard activeWorkspaceIDs.contains(workspaceID) else {
            toast = "请先打开这个工作区"
            return
        }
        if isFloatingWorkspaceVisible(workspaceID) {
            closeFloatingWorkspacePanel(for: workspaceID)
        } else {
            showFloatingWorkspacePanel(for: workspaceID)
        }
    }

    /// 把某个工作区加入统一浮窗（已存在则只是切到它并置顶）
    func showFloatingWorkspacePanel(for workspaceID: UUID) {
        guard activeWorkspaceIDs.contains(workspaceID) else { return }
        if let detached = detachedWorkspaceControllers[workspaceID] {
            detached.show()
            visibleFloatingWorkspaceIDs.insert(workspaceID)
            return
        }
        preferences.showFloatingConsole = true
        savePreferences()
        showFloatingConsole()
        if !floatingTabIDs.contains(workspaceID) {
            floatingTabIDs.append(workspaceID)
        }
        selectedFloatingWorkspaceID = workspaceID
        unifiedFloatingController?.show()
        refreshVisibleFloatingWorkspaceIDs()
        unifiedFloatingController?.relayout()
    }

    /// 把当前所有活跃工作区都放进统一浮窗
    func showAllFloatingWorkspacePanels() {
        let ids = activeWorkspaceIDs.filter { id in
            workspaces.contains(where: { $0.id == id }) && !detachedWorkspaceIDs.contains(id)
        }
        guard !ids.isEmpty else {
            if preferences.showFloatingConsole {
                showFloatingConsole()
            }
            return
        }
        showFloatingConsole()
        floatingTabIDs = ids
        selectedFloatingWorkspaceID = ids.first
        unifiedFloatingController?.show()
        refreshVisibleFloatingWorkspaceIDs()
    }

    /// 将任意工作区 Tab 从总控制台拆成独立悬浮窗。
    func detachWorkspacePanel(_ workspaceID: UUID, near screenPoint: NSPoint? = nil) {
        guard workspace(withID: workspaceID) != nil else { return }
        if let existing = detachedWorkspaceControllers[workspaceID] {
            existing.show(near: screenPoint)
            return
        }

        floatingTabIDs.removeAll { $0 == workspaceID }
        if selectedFloatingWorkspaceID == workspaceID {
            selectedFloatingWorkspaceID = floatingTabIDs.first
        }

        let controller = DetachedWorkspacePanelController(
            state: self,
            workspaceID: workspaceID
        )
        detachedWorkspaceControllers[workspaceID] = controller
        detachedWorkspaceIDs.insert(workspaceID)
        refreshVisibleFloatingWorkspaceIDs()
        unifiedFloatingController?.relayout()
        controller.show(near: screenPoint)

        if let name = workspace(withID: workspaceID)?.name {
            toast = "已将“\(name)”拖出为独立悬浮窗"
        }
    }

    /// 将独立窗口放回总控制台的 Tab 栏。
    func reattachWorkspacePanel(_ workspaceID: UUID) {
        disposeDetachedWorkspacePanel(for: workspaceID)
        if !floatingTabIDs.contains(workspaceID) {
            floatingTabIDs.append(workspaceID)
        }
        selectedFloatingWorkspaceID = workspaceID
        preferences.showFloatingConsole = true
        savePreferences()
        showFloatingConsole()
        unifiedFloatingController?.show()
        unifiedFloatingController?.relayout()
        refreshVisibleFloatingWorkspaceIDs()
    }

    /// 独立窗松手时命中总控制台的吸附区，则异步归位。异步销毁可避免
    /// 在 NSWindow.performDrag 的调用栈尚未退出时移除当前 contentView。
    @discardableResult
    func dockDetachedWorkspaceIfPossible(
        _ workspaceID: UUID,
        at screenPoint: NSPoint
    ) -> Bool {
        guard detachedWorkspaceIDs.contains(workspaceID),
              unifiedFloatingController?.acceptsWorkspaceDock(at: screenPoint) == true
        else {
            return false
        }
        DispatchQueue.main.async { [weak self] in
            self?.reattachWorkspacePanel(workspaceID)
        }
        return true
    }

    /// 仅隐藏独立窗；之后可从工作区页面重新显示。
    func closeDetachedWorkspacePanel(_ workspaceID: UUID) {
        disposeDetachedWorkspacePanel(for: workspaceID)
        refreshVisibleFloatingWorkspaceIDs()
    }

    /// 从统一浮窗移除某个工作区 Tab；若清空则销毁浮窗
    func closeFloatingWorkspacePanel(for workspaceID: UUID) {
        if detachedWorkspaceIDs.contains(workspaceID) {
            closeDetachedWorkspacePanel(workspaceID)
            return
        }
        floatingTabIDs.removeAll { $0 == workspaceID }
        if selectedFloatingWorkspaceID == workspaceID {
            selectedFloatingWorkspaceID = floatingTabIDs.first
        }
        if floatingTabIDs.isEmpty && !preferences.showFloatingConsole {
            unifiedFloatingController?.dispose()
            unifiedFloatingController = nil
        } else {
            unifiedFloatingController?.relayout()
        }
        refreshVisibleFloatingWorkspaceIDs()
    }

    private func disposeFloatingWorkspacePanel(for workspaceID: UUID) {
        disposeDetachedWorkspacePanel(for: workspaceID)
        closeFloatingWorkspacePanel(for: workspaceID)
    }

    private func disposeDetachedWorkspacePanel(for workspaceID: UUID) {
        detachedWorkspaceControllers[workspaceID]?.dispose()
        detachedWorkspaceControllers.removeValue(forKey: workspaceID)
        detachedWorkspaceIDs.remove(workspaceID)
    }

    private func refreshVisibleFloatingWorkspaceIDs() {
        visibleFloatingWorkspaceIDs = Set(floatingTabIDs).union(detachedWorkspaceIDs)
    }

    func endWorkspace(_ workspaceID: UUID, quitApplications: Bool = false) {
        guard let workspace = workspace(withID: workspaceID),
              activeWorkspaceIDs.contains(workspaceID) else {
            toast = "这个工作区没有打开"
            return
        }
        refresh()
        let members = workspace.applications ?? legacyApplications(for: workspace)
        let runningMembers = applications.filter { app in
            workspaceMembers(members, contain: app)
        }
        let otherWorkspaces = activeWorkspaces.filter { $0.id != workspaceID }
        let sharedPIDs = Set(runningMembers.compactMap { app in
            otherWorkspaces.contains { other in
                workspaceMembers(other.memberApplications, contain: app)
            } ? app.pid : nil
        })
        let exclusiveMembers = runningMembers.filter {
            !sharedPIDs.contains($0.pid)
        }
        if quitApplications {
            exclusiveMembers.forEach { _ = manager.quit($0) }
            toast = "已退出“\(workspace.name)” · 保留 \(sharedPIDs.count) 个共享应用"
        } else {
            exclusiveMembers.forEach(manager.hide)
            toast = "已退出“\(workspace.name)”并收起窗口 · 保留 \(sharedPIDs.count) 个共享应用"
        }
        activeWorkspaceIDs.removeAll { $0 == workspaceID }
        preparedWorkspaceMemberIDs.removeValue(forKey: workspaceID)
        disposeFloatingWorkspacePanel(for: workspaceID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
    }

    private func foldApplicationsUnrelated(to members: [WorkspaceApplication]) {
        for app in applications {
            let isMember = members.contains {
                if let bundleIdentifier = $0.bundleIdentifier {
                    return bundleIdentifier == app.bundleIdentifier
                }
                return $0.name == app.name
            }
            if isMember { continue }
            if let id = app.bundleIdentifier, preferences.excludedBundleIDs.contains(id) { continue }
            manager.minimizeAll(app)
        }
    }

    private func workspaceMembers(
        _ members: [WorkspaceApplication],
        contain app: RunningAppItem
    ) -> Bool {
        members.contains { member in
            if let bundleIdentifier = member.bundleIdentifier {
                return bundleIdentifier == app.bundleIdentifier
            }
            if let bundlePath = member.bundlePath {
                return bundlePath == app.bundleURL?.path
            }
            return member.name == app.name
        }
    }

    private func workspaceMemberID(for app: RunningAppItem) -> String {
        app.bundleIdentifier ?? app.bundleURL?.path ?? app.name
    }

    @discardableResult
    private func applyWorkspaceLayout(
        _ workspace: WorkspaceItem,
        restrictingTo memberIDs: Set<String>? = nil
    ) -> Int {
        guard let assignments = workspace.slotAssignments, !assignments.isEmpty else { return 0 }
        let regions = workspace.assignedLayout.regions

        // 摆位前刷新一次，确保拿到最新窗口状态
        refresh()
        var placed = 0
        var placedElements: [(pid: pid_t, element: AXUIElement)] = []

        // ═══ 阶段一：静默摆位（只设坐标大小，不置顶，不闪烁）═══
        for member in workspace.memberApplications {
            if let memberIDs, !memberIDs.contains(member.id) { continue }
            guard let slot = assignments[member.id],
                  regions.indices.contains(slot) else { continue }

            guard let app = runningApplication(for: member) else { continue }
            NSRunningApplication(processIdentifier: app.pid)?.unhide()

            // 一个应用可能同时暴露主窗口、桌宠、HUD 和提醒条。
            // AX 的窗口顺序不稳定，不能直接取 first，否则会把无标题悬浮窗当成主窗口分屏。
            let recordedCandidates = windows(in: workspace, for: member)
            let targetWindow = WorkspaceWindowSelection.preferredPrimaryWindow(
                in: recordedCandidates.isEmpty ? app.windows : recordedCandidates,
                appName: app.name
            )

            guard let w = targetWindow else { continue }

            // 快速检查：如果窗口已经在目标区域附近，跳过避免重复操作
            if isWindowNearRect(w, normalizedRect: regions[slot], tolerance: 12) {
                placed += 1
                // 已经就位的窗口不再置前，避免重试时造成网页反复闪烁。
                continue
            }

            if manager.placeQuiet(w, normalizedRect: regions[slot], spacing: 8) {
                placed += 1
                if let elem = findAXElement(for: w) {
                    placedElements.append((pid: app.pid, element: elem))
                }
            }
        }

        // ═══ 阶段二：统一置顶（所有窗口位置设好后，一次性提到最前）═══
        if !placedElements.isEmpty {
            bringWindowsToFront(placedElements)
        }

        return placed
    }

    /// 查找 AXUIElement（轻量版，仅用于置顶）
    private func findAXElement(for window: WindowItem) -> AXUIElement? {
        manager.accessibilityElement(for: window)
    }

    /// 将所有已摆放的窗口统一提到最前面（跨应用、高层级）
    private func bringWindowsToFront(_ windows: [(pid: pid_t, element: AXUIElement)]) {
        // 只取消隐藏，不轮流激活多个应用。轮流 activate 会让网页获得/失去
        // 焦点并触发连续重绘，看起来就是分屏后的持续闪烁。
        let pids = Set(windows.map(\.pid))
        for pid in pids {
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                runningApp.unhide()
            }
        }

        // 每个新摆放的窗口只 Raise 一次；已就位窗口不会进入这里。
        for (_, element) in windows {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, false as CFBoolean)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    }

    /// 检查窗口当前位置是否已在目标归一化矩形附近（避免重复摆放导致闪烁）
    private func isWindowNearRect(_ window: WindowItem, normalizedRect: CGRect, tolerance: CGFloat) -> Bool {
        guard manager.hasAccessibilityPermission,
              let screen = NSScreen.main else { return false }

        guard let element = manager.accessibilityElement(for: window) else { return false }

        // 读取当前 frame
        var posVal: CFTypeRef?, sizeVal: CFTypeRef?
        let posOK = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal) == .success
        let sizeOK = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success
        guard posOK, sizeOK,
              let pv = posVal, let sv = sizeVal else { return false }

        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &point)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        let currentFrame = CGRect(origin: point, size: size)

        // 计算目标 Cocoa 坐标
        let visible = screen.visibleFrame
        let targetCocoa = CGRect(
            x: visible.minX + normalizedRect.minX * visible.width,
            y: visible.minY + (1 - normalizedRect.maxY) * visible.height,
            width: max(120, normalizedRect.width * visible.width),
            height: max(90, normalizedRect.height * visible.height)
        )
        return abs(currentFrame.origin.x - targetCocoa.origin.x) < tolerance
            && abs(currentFrame.origin.y - targetCocoa.origin.y) < tolerance
            && abs(currentFrame.width - targetCocoa.width) < tolerance * 4
            && abs(currentFrame.height - targetCocoa.height) < tolerance * 4
    }

    private func launchWorkspaceMember(_ member: WorkspaceApplication) {
        let url: URL?
        if let path = member.bundlePath, FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        } else if let bundleIdentifier = member.bundleIdentifier {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        } else {
            url = nil
        }
        guard let url else {
            toast = "找不到 \(member.name) 的应用程序"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func duplicateWorkspace(_ workspace: WorkspaceItem) {
        let copy = WorkspaceItem(
            id: UUID(),
            name: workspace.name + " 副本",
            symbol: workspace.symbol,
            colorName: workspace.colorName,
            createdAt: Date(),
            windows: workspace.windows,
            applications: workspace.applications,
            autoLaunchApplicationIDs: workspace.autoLaunchApplicationIDs,
            layoutKind: workspace.layoutKind,
            slotAssignments: workspace.slotAssignments
        )
        workspaces.append(copy)
        save()
    }

    func deleteRecords(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        save()
    }

    func deleteWorkspace(_ item: WorkspaceItem) {
        if activeWorkspaceIDs.contains(item.id) {
            activeWorkspaceIDs.removeAll { $0 == item.id }
            preparedWorkspaceMemberIDs.removeValue(forKey: item.id)
            disposeFloatingWorkspacePanel(for: item.id)
        }
        workspaces.removeAll { $0.id == item.id }
        save()
    }

    func toggleSelected(_ window: WindowItem) {
        if selectedWindowIDs.contains(window.id) {
            selectedWindowIDs.remove(window.id)
        } else {
            selectedWindowIDs.insert(window.id)
        }
    }

    func performBatch(_ action: BatchAction) {
        let windows = applications.flatMap(\.windows).filter { selectedWindowIDs.contains($0.id) }
        for window in windows {
            switch action {
            case .show: manager.focus(window)
            case .minimize: manager.minimize(window)
            case .zoom: manager.toggleZoom(window)
            case .close: manager.close(window)
            }
        }
        toast = "已对 \(windows.count) 个窗口执行\(action.rawValue)"
        selectedWindowIDs.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    func quitSelectedApplications() {
        let selectedPIDs = Set(
            applications
                .flatMap(\.windows)
                .filter { selectedWindowIDs.contains($0.id) }
                .map(\.pid)
        )
        let selectedApps = applications.filter { selectedPIDs.contains($0.pid) }

        requestQuit(selectedApps)
        selectedWindowIDs.removeAll()
    }

    var selectedApplicationCount: Int {
        let selectedPIDs = Set(
            applications
                .flatMap(\.windows)
                .filter { selectedWindowIDs.contains($0.id) }
                .map(\.pid)
        )
        return selectedPIDs.count
    }

    func quitApps(_ ids: Set<String>) {
        let targets = applications.filter { ids.contains($0.id) }
        requestQuit(targets)
        showEndWork = false
    }

    func quitApplication(_ app: RunningAppItem) {
        requestQuit([app])
    }

    func performApplicationBatch(_ action: ApplicationBatchAction, ids: Set<String>) {
        let targets = applications.filter { ids.contains($0.id) }
        for app in targets {
            switch action {
            case .show: manager.show(app)
            case .hide: manager.hide(app)
            case .minimize: manager.minimizeAll(app)
            }
        }
        toast = "已对 \(targets.count) 个应用执行\(action.rawValue)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    private func requestQuit(_ targets: [RunningAppItem]) {
        let protectedBundleID = Bundle.main.bundleIdentifier ?? "com.foldesk.mac"
        let safeTargets = targets.filter {
            $0.pid != ProcessInfo.processInfo.processIdentifier &&
            $0.bundleIdentifier != protectedBundleID &&
            $0.bundleIdentifier != "com.foldesk.mac"
        }
        guard !safeTargets.isEmpty else {
            toast = "没有选择要退出的应用"
            return
        }

        let rejected = safeTargets.filter { manager.quit($0) == .failed }
        if rejected.isEmpty {
            toast = "已发送 \(safeTargets.count) 个正常退出请求，Foldesk 保持运行"
        } else {
            toast = "退出请求被拒绝：\(rejected.map(\.name).joined(separator: "、"))"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let stillRunning = safeTargets.filter {
                NSRunningApplication(processIdentifier: $0.pid) != nil
            }
            if stillRunning.isEmpty {
                self.toast = safeTargets.count == 1
                    ? "已退出 \(safeTargets[0].name)，Foldesk 保持运行"
                    : "已退出 \(safeTargets.count) 个应用，Foldesk 保持运行"
            } else {
                self.toast = "仍在运行：\(stillRunning.map(\.name).joined(separator: "、"))"
            }
            self.refresh()
        }
    }

    func savePreferences() {
        save()
    }

    private func currentStates() -> [SavedWindowState] {
        applications.flatMap { app in
            app.windows.compactMap(savedState(for:))
        }
    }

    private func savedState(for window: WindowItem) -> SavedWindowState? {
        guard let app = applications.first(where: { $0.pid == window.pid }) else { return nil }
        return SavedWindowState(
            appName: app.name,
            bundleIdentifier: app.bundleIdentifier,
            title: window.title,
            x: window.frame.origin.x,
            y: window.frame.origin.y,
            width: window.frame.width,
            height: window.frame.height,
            wasMinimized: window.isMinimized
        )
    }

    private func legacyApplications(for workspace: WorkspaceItem) -> [WorkspaceApplication] {
        var seen: Set<String> = []
        return workspace.windows.compactMap { window in
            let key = window.bundleIdentifier ?? window.appName
            guard seen.insert(key).inserted else { return nil }
            return WorkspaceApplication(
                name: window.appName,
                bundleIdentifier: window.bundleIdentifier,
                bundlePath: nil
            )
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: recordsKey),
           let value = try? decoder.decode([FoldRecord].self, from: data) { records = value }
        if let data = UserDefaults.standard.data(forKey: workspacesKey),
           let value = try? decoder.decode([WorkspaceItem].self, from: data) { workspaces = value }
        if let data = UserDefaults.standard.data(forKey: preferencesKey),
           let value = try? decoder.decode(AppPreferences.self, from: data) { preferences = value }
        if let data = UserDefaults.standard.data(forKey: activeWorkspaceKey),
           let value = try? decoder.decode([UUID].self, from: data) { activeWorkspaceIDs = value }
    }

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(records) { UserDefaults.standard.set(data, forKey: recordsKey) }
        if let data = try? encoder.encode(workspaces) { UserDefaults.standard.set(data, forKey: workspacesKey) }
        if let data = try? encoder.encode(preferences) { UserDefaults.standard.set(data, forKey: preferencesKey) }
        if let data = try? encoder.encode(activeWorkspaceIDs) { UserDefaults.standard.set(data, forKey: activeWorkspaceKey) }
    }
}

enum BatchAction: String {
    case show = "显示"
    case minimize = "最小化"
    case zoom = "放大"
    case close = "关闭窗口"
}

enum ApplicationBatchAction: String {
    case show = "显示"
    case hide = "隐藏"
    case minimize = "最小化全部窗口"
}
