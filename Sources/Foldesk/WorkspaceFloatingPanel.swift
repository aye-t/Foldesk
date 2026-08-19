import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class InteractiveFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// AppKit otherwise uses the first click only to prepare an inactive hosting
/// view, forcing users to click a SwiftUI button twice.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 所有悬浮窗共用同一套屏幕边界计算。外接屏拔插、不同缩放比例或较小
/// 可用区域下，先缩小窗口再修正原点，避免窗口尺寸本身大于屏幕而永久被裁切。
enum FloatingPanelGeometry {
    static func fittedSize(
        _ requested: NSSize,
        in visibleFrame: NSRect,
        margin: CGFloat = 8
    ) -> NSSize {
        NSSize(
            width: min(requested.width, max(1, visibleFrame.width - margin * 2)),
            height: min(requested.height, max(1, visibleFrame.height - margin * 2))
        )
    }

    static func constrained(
        _ frame: NSRect,
        to visibleFrame: NSRect,
        margin: CGFloat = 8
    ) -> NSRect {
        var result = frame
        result.size = fittedSize(result.size, in: visibleFrame, margin: margin)
        let minX = visibleFrame.minX + margin
        let minY = visibleFrame.minY + margin
        let maxX = visibleFrame.maxX - result.width - margin
        let maxY = visibleFrame.maxY - result.height - margin
        result.origin.x = min(max(result.minX, minX), maxX)
        result.origin.y = min(max(result.minY, minY), maxY)
        return result
    }
}

@MainActor
final class WorkspaceFloatingPanelController: NSObject, ObservableObject {
    @Published private(set) var isExpanded = false

    private weak var state: AppState?
    private let panel: NSPanel
    private var hasInitialPosition = false
    private var screenObserver: NSObjectProtocol?

    init(state: AppState) {
        self.state = state
        panel = InteractiveFloatingPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.level = .floating
        panel.hidesOnDeactivate = false
        // In collapsed mode the panel contains only the toolbar, so its blank
        // background is a safe and convenient drag target. Expanded content
        // disables this to keep rows and controls from turning into drag areas.
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = FirstMouseHostingView(
            rootView: FloatingConsolePanelView(
                controller: self
            )
            .environmentObject(state)
            .preferredColorScheme(state.preferences.appearance.colorScheme)
        )
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.constrainToCurrentScreen()
            }
        }
    }

    func show() {
        if !hasInitialPosition {
            positionInitially()
            hasInitialPosition = true
        } else {
            constrainToCurrentScreen()
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func dispose() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func toggleExpanded() {
        let oldFrame = panel.frame
        dragStartFrame = nil
        isExpanded.toggle()
        panel.isMovableByWindowBackground = !isExpanded
        updateFrame(anchoredTo: oldFrame, animated: true)
    }

    /// 由收起态点开（不依赖当前状态，确保一定展开）
    func expand() {
        guard !isExpanded else { return }
        toggleExpanded()
    }

    /// 工作区 Tab 数量变化后重新计算浮窗尺寸（尤其收起态宽度需随内容变化）
    func relayout() {
        guard panel.isVisible else { return }
        updateFrame(anchoredTo: panel.frame, animated: false)
    }

    /// 独立工作区拖到总控制台附近时，用稍微放大的热区提供自然吸附。
    func acceptsWorkspaceDock(at screenPoint: NSPoint) -> Bool {
        guard panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -46, dy: -46).contains(screenPoint)
    }

    private var dragStartFrame: NSRect?
    private var hadShadowBeforeDrag = false

    func dragChanged(translation: CGSize) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        if dragStartFrame == nil {
            dragStartFrame = panel.frame
            // 拖拽时禁用阴影——阴影实时重算非常卡
            hadShadowBeforeDrag = panel.hasShadow
            panel.hasShadow = false
        }
        guard let start = dragStartFrame else { return }
        // CATransaction 禁隐式动画 + setFrameOrigin 代替 setFrame(display:true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let newX = start.origin.x + translation.width
        let newY = start.origin.y - translation.height
        let constrainedFrame = FloatingPanelGeometry.constrained(
            NSRect(origin: NSPoint(x: newX, y: newY), size: start.size),
            to: screen.visibleFrame
        )
        panel.setFrameOrigin(constrainedFrame.origin)
        CATransaction.commit()
    }

    func dragEnded() {
        dragStartFrame = nil
        // 恢复阴影
        if hadShadowBeforeDrag {
            panel.hasShadow = true
            hadShadowBeforeDrag = false
        }
        // 最终位置做一次边界修正
        guard let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrame(
            FloatingPanelGeometry.constrained(panel.frame, to: screen.visibleFrame),
            display: false
        )
    }

    /// 原生拖拽开始（NativeDragView 调用）——禁阴影提升帧率
    func nativeDragStarted() {
        hadShadowBeforeDrag = panel.hasShadow
        panel.hasShadow = false
    }

    /// 原生拖拽结束——恢复阴影 + 边界修正
    func finishNativeDrag() {
        dragStartFrame = nil
        if hadShadowBeforeDrag {
            panel.hasShadow = true
            hadShadowBeforeDrag = false
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrame(
            FloatingPanelGeometry.constrained(panel.frame, to: screen.visibleFrame),
            display: false
        )
    }

    func applyAppearance(_ appearance: AppAppearance) {
        switch appearance {
        case .system:
            panel.appearance = nil
        case .light:
            panel.appearance = NSAppearance(named: .aqua)
        case .dark:
            panel.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private var panelSize: NSSize {
        isExpanded
            ? NSSize(width: 380, height: 600)
            : NSSize(width: 154, height: 50)
    }

    private func positionInitially() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = FloatingPanelGeometry.fittedSize(panelSize, in: visible)
        let frame = NSRect(
            x: visible.maxX - size.width - 14,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(FloatingPanelGeometry.constrained(frame, to: visible), display: true)
    }

    private func updateFrame(anchoredTo oldFrame: NSRect, animated: Bool) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = FloatingPanelGeometry.fittedSize(panelSize, in: visible)
        let frame = NSRect(
            x: oldFrame.maxX - size.width,
            y: oldFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(FloatingPanelGeometry.constrained(frame, to: visible), display: true, animate: animated)
    }

    private func constrainToCurrentScreen() {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        panel.setFrame(
            FloatingPanelGeometry.constrained(panel.frame, to: visible),
            display: false
        )
    }
}

@MainActor
final class DetachedWorkspacePanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isExpanded = true

    let workspaceID: UUID
    private weak var state: AppState?
    private let panel: InteractiveFloatingPanel
    private var hasInitialPosition = false
    private var hadShadowBeforeDrag = false
    private var mouseUpMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    private var positionKey: String {
        "foldesk.detachedWorkspacePanel.\(workspaceID.uuidString).origin"
    }

    init(state: AppState, workspaceID: UUID) {
        self.state = state
        self.workspaceID = workspaceID
        panel = InteractiveFloatingPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = FirstMouseHostingView(
            rootView: DetachedWorkspacePanelView(controller: self)
                .environmentObject(state)
                .preferredColorScheme(state.preferences.appearance.colorScheme)
        )
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) {
            [weak self] event in
            guard let self,
                  !self.isExpanded,
                  event.window === self.panel else {
                return event
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishNativeDrag()
            }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.constrainAndSavePosition()
            }
        }
    }

    func show(near screenPoint: NSPoint? = nil) {
        if !hasInitialPosition {
            positionInitially(near: screenPoint)
            hasInitialPosition = true
        } else {
            constrainAndSavePosition()
        }
        panel.orderFrontRegardless()
    }

    func dispose() {
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panel.delegate = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func toggleExpanded() {
        let oldFrame = panel.frame
        isExpanded.toggle()
        updateFrame(anchoredTo: oldFrame, animated: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.isMovableByWindowBackground = !self.isExpanded
        }
    }

    func nativeDragStarted() {
        hadShadowBeforeDrag = panel.hasShadow
        panel.hasShadow = false
    }

    func finishNativeDrag() {
        if hadShadowBeforeDrag {
            panel.hasShadow = true
            hadShadowBeforeDrag = false
        }
        if state?.dockDetachedWorkspaceIfPossible(
            workspaceID,
            at: NSEvent.mouseLocation
        ) == true {
            return
        }
        constrainAndSavePosition()
    }

    func applyAppearance(_ appearance: AppAppearance) {
        switch appearance {
        case .system: panel.appearance = nil
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func windowDidMove(_ notification: Notification) {
        savePosition()
    }

    private var panelSize: NSSize {
        if isExpanded {
            return NSSize(width: 330, height: 430)
        }
        let name = state?.workspace(withID: workspaceID)?.name ?? "工作区"
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textWidth = (name as NSString).size(withAttributes: [.font: font]).width
        // 图标、文字、箭头和必要内边距；短名称不再为固定宽度留大块空白。
        let adaptiveWidth = min(210, max(112, ceil(textWidth) + 88))
        return NSSize(width: adaptiveWidth, height: 40)
    }

    private func positionInitially(near screenPoint: NSPoint?) {
        let saved = UserDefaults.standard.string(forKey: positionKey).map(NSPointFromString)
        let point = screenPoint ?? saved
        let screen = point.flatMap { point in
            NSScreen.screens.first(where: { $0.frame.contains(point) })
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = FloatingPanelGeometry.fittedSize(panelSize, in: visible)
        let origin: NSPoint
        if let point {
            origin = NSPoint(x: point.x - size.width / 2, y: point.y - 26)
        } else {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        panel.setFrame(
            FloatingPanelGeometry.constrained(NSRect(origin: origin, size: size), to: visible),
            display: true
        )
    }

    private func updateFrame(anchoredTo oldFrame: NSRect, animated: Bool) {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = FloatingPanelGeometry.fittedSize(panelSize, in: visible)
        let frame = NSRect(
            x: oldFrame.minX,
            y: oldFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(FloatingPanelGeometry.constrained(frame, to: visible), display: true, animate: animated)
        savePosition()
    }

    private func constrainAndSavePosition() {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        panel.setFrame(FloatingPanelGeometry.constrained(panel.frame, to: visible), display: false)
        savePosition()
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: positionKey)
    }

}

private struct DetachedWorkspacePanelView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: DetachedWorkspacePanelController

    private var workspace: WorkspaceItem? {
        state.workspace(withID: controller.workspaceID)
    }

    var body: some View {
        Group {
            if controller.isExpanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: controller.isExpanded ? 16 : 14))
        .overlay(
            RoundedRectangle(cornerRadius: controller.isExpanded ? 16 : 14)
                .stroke(Color.panelBorder)
        )
        .padding(4)
        .onAppear { controller.applyAppearance(state.preferences.appearance) }
        .onChange(of: state.preferences.appearance) {
            controller.applyAppearance(state.preferences.appearance)
        }
    }

    private var collapsedContent: some View {
        HStack(spacing: 6) {
            workspaceBadge(size: 22)
            Text(workspace?.name ?? "工作区")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { controller.toggleExpanded() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.plain)
            .help("展开独立工作区")
        }
        .padding(.horizontal, 7)
        .frame(height: 32)
        .contentShape(Rectangle())
        .contextMenu {
            Button("在 Foldesk 中打开") { openInFoldesk() }
            Button("归位到总悬浮窗") {
                state.reattachWorkspacePanel(controller.workspaceID)
            }
            Divider()
            Button("隐藏悬浮标签") {
                state.closeDetachedWorkspacePanel(controller.workspaceID)
            }
        }
        .help("拖动移动；拖到总悬浮窗附近可归位")
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            ZStack {
                FloatingPanelDragSurface(
                    onClick: {},
                    onDragEnded: { controller.finishNativeDrag() },
                    onDragStarted: { controller.nativeDragStarted() },
                    onOpen: { openInFoldesk() },
                    onHide: { state.closeDetachedWorkspacePanel(controller.workspaceID) },
                    onClose: { state.endWorkspace(controller.workspaceID) }
                )

                HStack(spacing: 9) {
                    workspaceBadge(size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace?.name ?? "工作区")
                            .font(.headline)
                        Text(workspace.map(workspaceSummary) ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { state.reattachWorkspacePanel(controller.workspaceID) } label: {
                        Image(systemName: "arrow.uturn.down")
                    }
                    .buttonStyle(.borderless)
                    .help("归位到总悬浮窗")
                    Button { controller.toggleExpanded() } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .help("收起独立工作区")
                    Button { state.closeDetachedWorkspacePanel(controller.workspaceID) } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("隐藏独立工作区")
                }
                .padding(12)
            }
            .frame(height: 60)

            Divider()

            if let workspace {
                WorkspaceControlList(workspace: workspace, compact: true)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(10)

                Divider()

                HStack(spacing: 10) {
                    if state.isWorkspaceActive(workspace.id) {
                        Button("打开全部") { state.openAllWorkspaceMembers(in: workspace.id) }
                            .buttonStyle(.borderedProminent)
                        Button("退出工作区") { state.endWorkspace(workspace.id) }
                            .foregroundStyle(Color.foldeskRed)
                    } else {
                        Button { state.openWorkspace(workspace) } label: {
                            Label("进入工作区", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("归位") { state.reattachWorkspacePanel(workspace.id) }
                }
                .controlSize(.small)
                .padding(12)
            } else {
                ContentUnavailableView("工作区已删除", systemImage: "questionmark.folder")
            }
        }
    }

    private func workspaceBadge(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26)
                .fill(workspace.map(color)?.opacity(0.13) ?? Color.secondary.opacity(0.12))
            Image(systemName: workspace?.symbol ?? "briefcase.fill")
                .foregroundStyle(workspace.map(color) ?? .secondary)
        }
        .frame(width: size, height: size)
    }

    private var panelBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.105, blue: 0.115).opacity(0.98)
            : Color(nsColor: .windowBackgroundColor).opacity(0.985)
    }

    private func color(_ workspace: WorkspaceItem) -> Color {
        switch workspace.colorName {
        case "purple": .purple
        case "orange": .orange
        case "green": .green
        default: .foldeskBlue
        }
    }

    private func workspaceSummary(_ workspace: WorkspaceItem) -> String {
        let running = workspace.memberApplications.filter { state.runningApplication(for: $0) != nil }
        let windows = running.reduce(0) { $0 + (state.runningApplication(for: $1)?.windows.count ?? 0) }
        return "\(running.count)/\(workspace.applicationCount) 个应用运行 · \(windows) 个窗口"
    }

    private func openInFoldesk() {
        state.selection = .workspaces
        state.summonApp()
    }
}

private struct WorkspaceFloatingPanelView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: WorkspaceFloatingPanelController
    @State private var isEditing = false
    @State private var selectedTab = 0

    /// 当前选中的工作区（Tab）；无显式选中时回退到第一个 Tab
    private var activeWorkspaceID: UUID? {
        state.selectedFloatingWorkspaceID ?? state.floatingTabIDs.first
    }

    private var workspace: WorkspaceItem? {
        if let id = activeWorkspaceID { return state.workspace(withID: id) }
        return nil
    }

    var body: some View {
        Group {
            if controller.isExpanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: controller.isExpanded ? 18 : 12))
        .overlay(
            RoundedRectangle(cornerRadius: controller.isExpanded ? 18 : 12)
                .stroke(Color.panelBorder)
        )
        .padding(4)
        .preferredColorScheme(state.preferences.appearance.colorScheme)
        .onAppear {
            controller.applyAppearance(state.preferences.appearance)
        }
        .onChange(of: state.preferences.appearance) {
            controller.applyAppearance(state.preferences.appearance)
        }
        .contextMenu {
            Button("在 Foldesk 中打开") {
                openInFoldesk()
            }
            if controller.isExpanded {
                Button("收起为悬浮标签") {
                    controller.toggleExpanded()
                }
            }
            Divider()
            Button("隐藏悬浮标签") {
                if let id = activeWorkspaceID {
                    state.closeFloatingWorkspacePanel(for: id)
                }
            }
            Button("退出工作区", role: .destructive) {
                if let id = activeWorkspaceID {
                    state.endWorkspace(id)
                }
            }
        }
    }

    // MARK: - 收起态：自适应宽度的多工作区标签栏

    private var collapsedContent: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.floatingTabIDs, id: \.self) { id in
                        if let ws = state.workspace(withID: id) {
                            collapsedPill(ws, isSelected: id == activeWorkspaceID)
                                .onTapGesture {
                                    state.selectedFloatingWorkspaceID = id
                                    controller.expand()
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            Button {
                controller.toggleExpanded()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(height: 38)
        .contentShape(Rectangle())
        .overlay(
            FloatingPanelDragSurface(
                onClick: { controller.toggleExpanded() },
                onDragEnded: { controller.finishNativeDrag() },
                onDragStarted: { controller.nativeDragStarted() },
                onOpen: { openInFoldesk() },
                onHide: {
                    if let id = activeWorkspaceID {
                        state.closeFloatingWorkspacePanel(for: id)
                    }
                },
                onClose: {
                    if let id = activeWorkspaceID {
                        state.endWorkspace(id)
                    }
                }
            )
        )
        .help("点标签展开对应工作区；拖动移动浮窗；右击可隐藏或关闭")
    }

    private func collapsedPill(_ ws: WorkspaceItem, isSelected: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(runningDotColor(for: ws))
                .frame(width: 7, height: 7)
            Image(systemName: ws.symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color(for: ws))
            Text(ws.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let suffix = statusSuffix(for: ws) {
                Text(suffix)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? color(for: ws) : Color.panelBorder)
        )
    }

    /// 未运行灰点，运行中绿点
    private func runningDotColor(for ws: WorkspaceItem) -> Color {
        let running = ws.memberApplications.contains { state.runningApplication(for: $0) != nil }
        return running ? Color.foldeskGreen : Color(red: 0.79, green: 0.78, blue: 0.75)
    }

    /// 收起标签后缀：随工作区内容变化，让标签宽度自适应
    private func statusSuffix(for ws: WorkspaceItem) -> String? {
        if let slots = ws.slotAssignments, !slots.isEmpty {
            return "· 分屏"
        }
        let running = ws.memberApplications.contains { state.runningApplication(for: $0) != nil }
        if running { return "· 运行" }
        return "· 未启动"
    }

    // MARK: - 展开态：Tab 栏 + 当前工作区内容

    private var expandedContent: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()

            if let workspace {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.foldeskBlue.opacity(0.12))
                        Image(systemName: workspace.symbol)
                            .foregroundStyle(Color.foldeskBlue)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.name).font(.headline)
                        Text("\(workspace.applicationCount) 个应用 · \(workspace.windows.count) 个窗口")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        isEditing.toggle()
                    } label: {
                        Image(systemName: isEditing ? "checkmark" : "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help(isEditing ? "完成编辑" : "编辑工作区")
                    Button {
                        controller.toggleExpanded()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help("收起控制器")
                }
                .padding(14)
                .contentShape(Rectangle())
                .overlay(
                    FloatingPanelDragSurface(
                        onClick: { /* 展开态标题栏点击不做额外操作 */ },
                        onDragEnded: { controller.finishNativeDrag() },
                        onDragStarted: { controller.nativeDragStarted() },
                        onOpen: { openInFoldesk() },
                        onHide: {
                            if let id = activeWorkspaceID {
                                state.closeFloatingWorkspacePanel(for: id)
                            }
                        },
                        onClose: {
                            if let id = activeWorkspaceID {
                                state.endWorkspace(id)
                            }
                        }
                    )
                )

                Divider()

                Picker("控制器页面", selection: $selectedTab) {
                    Text("应用").tag(0)
                    Text("分屏布局").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                Divider()

                Group {
                    if selectedTab == 0 {
                        applicationPane(workspace)
                    } else {
                        layoutPane(workspace)
                    }
                }
                .frame(maxHeight: .infinity)

                Divider()

                HStack {
                    if selectedTab == 0 {
                        Button("打开全部") {
                            if let id = activeWorkspaceID {
                                state.openAllWorkspaceMembers(in: id)
                            }
                        }
                    } else {
                        Button {
                            if let id = activeWorkspaceID {
                                state.applyActiveWorkspaceLayout(in: id)
                            }
                        } label: {
                            Label("开始分屏", systemImage: "rectangle.split.2x1")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Spacer()
                    Button("打开 Foldesk") {
                        openInFoldesk()
                    }
                    Button("退出工作区") {
                        if let id = activeWorkspaceID {
                            state.endWorkspace(id)
                        }
                    }
                    .foregroundStyle(Color.foldeskRed)
                }
                .padding(12)
                .font(.caption)
                .buttonStyle(.plain)
            } else {
                Text("没有正在使用的工作区")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.floatingTabIDs, id: \.self) { id in
                    if let ws = state.workspace(withID: id) {
                        tabPill(ws, isSelected: id == activeWorkspaceID)
                            .onTapGesture {
                                state.selectedFloatingWorkspaceID = id
                                selectedTab = 0
                            }
                    }
                }
                Menu {
                    let candidates = state.workspaces.filter { !state.floatingTabIDs.contains($0.id) }
                    if candidates.isEmpty {
                        Text("没有更多工作区")
                    } else {
                        Section("加入浮窗") {
                            ForEach(candidates) { ws in
                                Button(ws.name) { state.openWorkspace(ws) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
            }
            .padding(10)
        }
    }

    private func tabPill(_ ws: WorkspaceItem, isSelected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ws.symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color(for: ws))
            Text(ws.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if isSelected {
                Button {
                    if let id = activeWorkspaceID {
                        state.closeFloatingWorkspacePanel(for: id)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("从浮窗移除该工作区")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(isSelected ? Color.white : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            isSelected
                ? RoundedRectangle(cornerRadius: 7).stroke(color(for: ws))
                : nil
        )
        .shadow(
            color: isSelected ? Color.black.opacity(0.08) : .clear,
            radius: 1,
            y: 0.5
        )
    }

    private var panelBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.105, blue: 0.115).opacity(0.98)
            : Color.white.opacity(0.98)
    }

    private func openInFoldesk() {
        state.selection = .workspaces
        openWindow(id: "main")
        DispatchQueue.main.async {
            state.summonApp()
        }
    }

    private func color(for ws: WorkspaceItem) -> Color {
        switch ws.colorName {
        case "purple": .purple
        case "orange": .orange
        case "green": .green
        default: .foldeskBlue
        }
    }

    private func applicationPane(_ workspace: WorkspaceItem) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                if isEditing {
                    ForEach(workspace.memberApplications) { member in
                        editableMemberRow(member, workspace: workspace)
                    }
                    addApplicationMenu(workspace)
                } else {
                    WorkspaceControlList(workspace: workspace, compact: true)
                }
            }
            .padding(10)
        }
    }

    private func editableMemberRow(
        _ member: WorkspaceApplication,
        workspace: WorkspaceItem
    ) -> some View {
        HStack(spacing: 9) {
            AppIcon(image: icon(for: member), size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(workspace.slot(for: member).map { "槽位 \($0 + 1)" } ?? "未绑定槽位")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "自动",
                isOn: Binding(
                    get: {
                        state.workspace(withID: workspace.id)?
                            .autoLaunchIDs.contains(member.id) ?? false
                    },
                    set: {
                        state.setWorkspaceAutoLaunch(
                            $0,
                            member: member,
                            workspaceID: workspace.id
                        )
                    }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption2)
            Button {
                state.removeWorkspaceMember(member, workspaceID: workspace.id)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(Color.foldeskRed)
            }
            .buttonStyle(.plain)
            .help("从工作区移除，不退出应用")
        }
        .padding(9)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func addApplicationMenu(_ workspace: WorkspaceItem) -> some View {
        Menu {
            let existingIDs = Set(workspace.memberApplications.map(\.id))
            let candidates = state.applications.filter {
                !existingIDs.contains($0.id) && $0.bundleURL != nil
            }
            if !candidates.isEmpty {
                Section("正在运行") {
                    ForEach(candidates) { app in
                        Button(app.name) {
                            if let url = app.bundleURL {
                                state.addApplication(url, toWorkspace: workspace.id)
                            }
                        }
                    }
                }
            }
            Button("从“应用程序”选择…") {
                chooseApplications(for: workspace)
            }
        } label: {
            Label("添加应用", systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton)
        .padding(8)
        .background(Color.foldeskBlue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func layoutPane(_ workspace: WorkspaceItem) -> some View {
        VStack(spacing: 10) {
            Picker(
                "分屏模板",
                selection: Binding(
                    get: {
                        state.workspace(withID: workspace.id)?.assignedLayout ?? .focus
                    },
                    set: { state.setWorkspaceLayout($0, workspaceID: workspace.id) }
                )
            ) {
                ForEach(WorkspaceLayoutKind.allCases) { kind in
                    Label(kind.rawValue, systemImage: kind.symbol).tag(kind)
                }
            }
            .labelsHidden()

            WorkspaceLayoutAssignmentView(workspaceID: workspace.id)
                .environmentObject(state)
                .frame(maxHeight: .infinity)

            Text("点击槽位分配应用；未运行的应用会在分屏时自动启动。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let feedback = state.workspaceLayoutFeedback[workspace.id] {
                Label(
                    feedback,
                    systemImage: feedbackIcon(for: feedback)
                )
                .font(.caption2)
                .foregroundStyle(feedbackColor(for: feedback))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            }
        }
        .padding(12)
    }

    private func chooseApplications(for workspace: WorkspaceItem) {
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
            state.addApplication(url, toWorkspace: workspace.id)
        }
    }

    private func icon(for member: WorkspaceApplication) -> NSImage {
        if let running = state.runningApplication(for: member) {
            return running.icon
        }
        if let path = member.bundlePath {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ??
            NSImage(size: NSSize(width: 24, height: 24))
    }

    // MARK: - 分屏反馈样式

    private func feedbackIcon(for feedback: String) -> String {
        // 全成功
        if feedback.contains("✓") { return "checkmark.circle.fill" }
        // 解析 "已排列 X/Y" 格式
        if feedback.contains("已排列") && feedback.contains("/") {
            let parts = feedback.components(separatedBy: "/")
            if parts.count >= 2 {
                let placed = Int(parts[0].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
                let total = Int(parts[1].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
                if placed >= total && total > 0 { return "checkmark.circle.fill" }
                if placed > 0 { return "exclamationmark.triangle.fill" }
            }
        }
        // 错误/失败
        if feedback.contains("无法分屏") || feedback.contains("失败") || feedback.contains("请先") {
            return "xmark.circle.fill"
        }
        // 进行中
        if feedback.contains("正在启动") || feedback.contains("等待") {
            return "clock.arrow.circlepath"
        }
        return "info.circle.fill"
    }

    private func feedbackColor(for feedback: String) -> Color {
        if feedback.contains("✓") { return Color.foldeskGreen }
        if feedback.contains("已排列") && feedback.contains("/") {
            let parts = feedback.components(separatedBy: "/")
            if parts.count >= 2 {
                let placed = Int(parts[0].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
                let total = Int(parts[1].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
                if placed >= total && total > 0 { return Color.foldeskGreen }
                if placed > 0 { return Color.foldeskOrange }
            }
        }
        if feedback.contains("无法分屏") || feedback.contains("失败") { return Color.foldeskRed }
        if feedback.contains("正在启动") || feedback.contains("等待") { return .secondary }
        return Color.foldeskOrange
    }
}

struct FloatingPanelDragSurface: NSViewRepresentable {
    let onClick: () -> Void
    let onDragEnded: () -> Void
    let onDragStarted: (() -> Void)?
    let onOpen: () -> Void
    let onHide: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onClick: onClick,
            onDragEnded: onDragEnded,
            onOpen: onOpen,
            onHide: onHide,
            onClose: onClose
        )
    }

    func makeNSView(context: Context) -> NativeDragView {
        let view = NativeDragView()
        view.coordinator = context.coordinator
        // 把阴影控制注入 coordinator
        context.coordinator.onDragStarted = onDragStarted
        return view
    }

    func updateNSView(_ nsView: NativeDragView, context: Context) {
        context.coordinator.onClick = onClick
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onDragStarted = onDragStarted
        context.coordinator.onOpen = onOpen
        context.coordinator.onHide = onHide
        context.coordinator.onClose = onClose
    }

    @MainActor
    final class Coordinator: NSObject {
        var onClick: () -> Void
        var onDragEnded: () -> Void
        var onDragStarted: (() -> Void)?
        var onOpen: () -> Void
        var onHide: () -> Void
        var onClose: () -> Void

        init(
            onClick: @escaping () -> Void,
            onDragEnded: @escaping () -> Void,
            onOpen: @escaping () -> Void,
            onHide: @escaping () -> Void,
            onClose: @escaping () -> Void
        ) {
            self.onClick = onClick
            self.onDragEnded = onDragEnded
            self.onOpen = onOpen
            self.onHide = onHide
            self.onClose = onClose
        }

        @objc func open() { onOpen() }
        @objc func hide() { onHide() }
        @objc func close() { onClose() }
    }

    @MainActor
    final class NativeDragView: NSView {
        weak var coordinator: Coordinator?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let originalOrigin = window.frame.origin
            coordinator?.onDragStarted?()
            NSCursor.closedHand.push()
            defer { NSCursor.pop() }
            window.performDrag(with: event)
            coordinator?.onDragEnded()
            let distance = hypot(
                window.frame.origin.x - originalOrigin.x,
                window.frame.origin.y - originalOrigin.y
            )
            if distance < 2 {
                coordinator?.onClick()
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let coordinator else { return }
            let menu = NSMenu()

            let openItem = NSMenuItem(
                title: "在 Foldesk 中打开",
                action: #selector(Coordinator.open),
                keyEquivalent: ""
            )
            openItem.target = coordinator
            menu.addItem(openItem)
            menu.addItem(.separator())

            let hideItem = NSMenuItem(
                title: "隐藏悬浮标签",
                action: #selector(Coordinator.hide),
                keyEquivalent: ""
            )
            hideItem.target = coordinator
            menu.addItem(hideItem)

            let closeItem = NSMenuItem(
                title: "退出工作区",
                action: #selector(Coordinator.close),
                keyEquivalent: ""
            )
            closeItem.target = coordinator
            menu.addItem(closeItem)

            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

private struct WorkspaceLayoutAssignmentView: View {
    @EnvironmentObject private var state: AppState
    let workspaceID: UUID

    private var workspace: WorkspaceItem? {
        state.workspaces.first { $0.id == workspaceID }
    }

    var body: some View {
        GeometryReader { proxy in
            if let workspace {
                let regions = workspace.assignedLayout.regions
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.primary.opacity(0.055))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13)
                                .stroke(Color.panelBorder)
                        )
                    ForEach(regions.indices, id: \.self) { slot in
                        slotView(slot, workspace: workspace)
                            .frame(
                                width: max(60, regions[slot].width * proxy.size.width - 8),
                                height: max(52, regions[slot].height * proxy.size.height - 8)
                            )
                            .position(
                                x: regions[slot].midX * proxy.size.width,
                                y: regions[slot].midY * proxy.size.height
                            )
                    }
                }
            }
        }
        .frame(minHeight: 220)
    }

    /// 槽位状态枚举
    private enum SlotStatus {
        case empty           // 没分配应用
        case notRunning      // 分配了但应用没运行
        case running         // 应用在运行
        case noWindow        // 应用运行但没有窗口（罕见）
    }

    private func status(for member: WorkspaceApplication?) -> SlotStatus {
        guard let member else { return .empty }
        if state.runningApplication(for: member) == nil { return .notRunning }
        return .running
    }

    private func slotView(_ slot: Int, workspace: WorkspaceItem) -> some View {
        let assigned = workspace.memberApplications.first {
            workspace.slot(for: $0) == slot
        }
        let slotStatus = status(for: assigned)

        return Menu {
            Button("保持空白") {
                state.assignWorkspaceMember(nil, to: slot, workspaceID: workspace.id)
            }
            Divider()
            ForEach(workspace.memberApplications) { member in
                Button(member.name) {
                    state.assignWorkspaceMember(member, to: slot, workspaceID: workspace.id)
                }
            }
        } label: {
            VStack(spacing: 6) {
                if let assigned {
                    AppIcon(image: icon(for: assigned), size: 24)
                } else {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.tertiary)
                }

                Text(assigned?.name ?? "槽位 \(slot + 1)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                // 根据真实状态显示不同文案和样式
                switch slotStatus {
                case .empty:
                    Text("点击分配应用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .notRunning:
                    HStack(spacing: 3) {
                        Text("未运行")
                            .font(.caption2)
                            .foregroundStyle(Color.foldeskOrange)
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.foldeskBlue)
                    }
                case .running:
                    Text("已打开 · 点击更换")
                        .font(.caption2)
                        .foregroundStyle(Color.foldeskGreen)
                case .noWindow:
                    Text("无窗口")
                        .font(.caption2)
                        .foregroundStyle(Color.foldeskOrange)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(assigned == nil ? Color.secondary : Color.foldeskBlue)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(slotBorderColor(for: slotStatus))
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
            // 未运行时：点击整个槽位可以唤醒
            .onTapGesture(count: 2) {
                if case .notRunning = slotStatus, let assigned {
                    state.showWorkspaceMember(assigned, in: workspaceID)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .help(slotHelpText(for: slotStatus, member: assigned))
    }

    private func slotBorderColor(for status: SlotStatus) -> Color {
        switch status {
        case .empty: Color.panelBorder
        case .notRunning: Color.foldeskOrange.opacity(0.55)
        case .running: Color.foldeskGreen.opacity(0.55)
        case .noWindow: Color.foldeskOrange.opacity(0.55)
        }
    }

    private func slotHelpText(for status: SlotStatus, member: WorkspaceApplication?) -> String {
        switch status {
        case .empty: return "点击选择要放入此槽位的应用"
        case .notRunning: return "\(member?.name ?? "") 未运行，双击唤醒"
        case .running: return "\(member?.name ?? "") 已在运行，点击更换"
        case .noWindow: return "\(member?.name ?? "") 运行中但无窗口"
        }
    }

    private func icon(for member: WorkspaceApplication) -> NSImage {
        if let running = state.runningApplication(for: member) {
            return running.icon
        }
        if let path = member.bundlePath {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 24, height: 24))
    }
}
