import AppKit
import SwiftUI

private enum FloatingConsolePage: Int {
    case windows
    case workspaces
}

private struct FloatingWindowEntry: Identifiable {
    let application: RunningAppItem
    let window: WindowItem

    var id: String {
        "\(application.id)|\(window.id)"
    }
}

struct FloatingConsolePanelView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: WorkspaceFloatingPanelController

    @State private var selectedPage: FloatingConsolePage = .windows
    @State private var selectedWorkspaceID: UUID?
    @State private var searchText = ""
    @State private var workspaceTabDragOffsets: [UUID: CGSize] = [:]

    private var dockedWorkspaces: [WorkspaceItem] {
        state.workspaces.filter { !state.detachedWorkspaceIDs.contains($0.id) }
    }

    private var windowEntries: [FloatingWindowEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.applications.flatMap { application in
            application.windows.compactMap { window in
                guard query.isEmpty ||
                        application.name.localizedCaseInsensitiveContains(query) ||
                        window.title.localizedCaseInsensitiveContains(query)
                else {
                    return nil
                }
                return FloatingWindowEntry(application: application, window: window)
            }
        }
    }

    private var selectedWorkspace: WorkspaceItem? {
        let preferredID =
            selectedWorkspaceID ??
            state.selectedFloatingWorkspaceID ??
            state.activeWorkspaceIDs.first ??
            dockedWorkspaces.first?.id
        if let preferredID,
           !state.detachedWorkspaceIDs.contains(preferredID) {
            return state.workspace(withID: preferredID)
        }
        return dockedWorkspaces.first
    }

    var body: some View {
        VStack(spacing: controller.isExpanded ? 8 : 0) {
            compactToolbar

            if controller.isExpanded {
                expandedPanel
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(4)
        .preferredColorScheme(state.preferences.appearance.colorScheme)
        .onAppear {
            controller.applyAppearance(state.preferences.appearance)
            state.refresh()
            selectInitialWorkspace()
        }
        .onChange(of: state.preferences.appearance) {
            controller.applyAppearance(state.preferences.appearance)
        }
        .onChange(of: state.selectedFloatingWorkspaceID) {
            if let id = state.selectedFloatingWorkspaceID {
                selectedWorkspaceID = id
            }
        }
        .task(id: controller.isExpanded) {
            guard controller.isExpanded else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                state.refresh()
            }
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 0) {
            Image(nsImage: .foldeskBrandIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 29, height: 29)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(width: 50, height: 42)
                .contentShape(Rectangle())
                .overlay(
                    FloatingPanelDragSurface(
                        // The icon is a drag handle only. Keeping expansion on
                        // the chevron prevents a short drag from opening the panel.
                        onClick: {},
                        onDragEnded: { controller.finishNativeDrag() },
                        onDragStarted: { controller.nativeDragStarted() },
                        onOpen: { openMain(.applications) },
                        onHide: { state.setFloatingConsoleVisibility(false) },
                        onClose: { state.setFloatingConsoleVisibility(false) }
                    )
                )
                .help("按住拖动悬浮控制台；点击右侧箭头展开")

            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1, height: 24)

            Button {
                state.returnToDesktop()
            } label: {
                Image(systemName: "display")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 40, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("一键回到桌面")

            Button {
                controller.toggleExpanded()
            } label: {
                Image(systemName: controller.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.isExpanded ? "收起控制台" : "展开控制台")
        }
        .frame(width: 142, height: 42)
        .background(toolbarBackground)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.16)))
        .shadow(color: .black.opacity(0.14), radius: 9, y: 4)
        .contentShape(Capsule())
        .contextMenu {
            Button("打开 Foldesk") {
                openMain(.applications)
            }
            Button(controller.isExpanded ? "收起控制台" : "展开控制台") {
                controller.toggleExpanded()
            }
            Divider()
            Button("隐藏悬浮控制台") {
                state.setFloatingConsoleVisibility(false)
            }
        }
    }

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            Picker("控制台页面", selection: $selectedPage) {
                Text("窗口").tag(FloatingConsolePage.windows)
                Text("工作区").tag(FloatingConsolePage.workspaces)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 15)
            .padding(.bottom, 11)

            Group {
                switch selectedPage {
                case .windows:
                    windowsPage
                case .workspaces:
                    workspacesPage
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.primary.opacity(0.14)))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 7)
        .overlay(alignment: .top) {
            FloatingPopoverArrow()
                .fill(panelBackground)
                .frame(width: 22, height: 11)
                .overlay {
                    FloatingPopoverArrow()
                        .stroke(Color.primary.opacity(0.14))
                }
                .offset(y: -10)
        }
    }

    private var windowsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("窗口总览")
                        .font(.title3.bold())
                    Text("\(state.windowCount) 个窗口 · \(state.applications.filter { !$0.windows.isEmpty }.count) 个应用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新窗口")
            }

            searchField

            if windowEntries.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "当前没有窗口" : "没有匹配的窗口",
                    systemImage: "macwindow.on.rectangle",
                    description: Text(searchText.isEmpty ? "打开应用后，窗口会显示在这里。" : "换一个关键词再试试。")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(windowEntries.prefix(8)) { entry in
                            floatingWindowRow(entry)
                            if entry.id != windowEntries.prefix(8).last?.id {
                                Divider()
                                    .padding(.leading, 46)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                Button {
                    openMain(.applications)
                } label: {
                    HStack {
                        Text(windowEntries.count > 8 ? "查看全部 \(windowEntries.count) 个窗口" : "在 Foldesk 中查看")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
            }

            if !state.workspaces.isEmpty {
                Divider()
                quickWorkspaceSection
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索窗口", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.panelBorder))
    }

    private func floatingWindowRow(_ entry: FloatingWindowEntry) -> some View {
        HStack(spacing: 10) {
            AppIcon(image: entry.application.icon, size: 32)

            Button {
                state.focusWorkspaceWindow(entry.window)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.window.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(entry.application.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Text(windowStatus(entry))
                .font(.caption2.weight(.medium))
                .foregroundStyle(windowStatusColor(entry))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(windowStatusColor(entry).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            floatingActionButton("eye", help: "显示并聚焦窗口") {
                state.focusWorkspaceWindow(entry.window)
            }
            floatingActionButton(
                "arrow.up.left.and.arrow.down.right",
                help: "放大或还原窗口",
                disabled: entry.window.isMinimized
            ) {
                state.zoomWorkspaceWindow(entry.window)
            }
            floatingActionButton("minus", help: "最小化窗口", disabled: entry.window.isMinimized) {
                state.minimizeWorkspaceWindow(entry.window)
            }
            floatingActionButton("xmark", help: "关闭窗口", destructive: true) {
                state.closeWorkspaceWindow(entry.window)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            state.focusWorkspaceWindow(entry.window)
        }
    }

    private func floatingActionButton(
        _ symbol: String,
        help: String,
        disabled: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(destructive ? Color.foldeskRed : Color.primary)
                .frame(width: 21, height: 21)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.28 : 1)
        .help(help)
    }

    private var quickWorkspaceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("快速切换到工作区")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dockedWorkspaces.prefix(4)) { workspace in
                        Button {
                            selectWorkspace(workspace)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: workspace.symbol)
                                    .foregroundStyle(color(for: workspace))
                                Text(workspace.name)
                                    .lineLimit(1)
                                if state.isWorkspaceActive(workspace.id) {
                                    Circle()
                                        .fill(Color.foldeskGreen)
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Color.primary.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.panelBorder))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var workspacesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("工作区")
                        .font(.title3.bold())
                    Text("\(state.activeWorkspaceIDs.count) 个正在使用 · \(state.workspaces.count) 个已保存")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    openMain(.workspaces)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("在 Foldesk 中管理工作区")
            }

            if state.workspaces.isEmpty {
                ContentUnavailableView(
                    "还没有工作区",
                    systemImage: "rectangle.3.group",
                    description: Text("在 Foldesk 中创建工作区后，可以从这里快速打开。")
                )
                .frame(maxHeight: .infinity)
            } else if dockedWorkspaces.isEmpty {
                ContentUnavailableView(
                    "工作区均已拖出",
                    systemImage: "macwindow.on.rectangle",
                    description: Text("可在独立工作区窗口中点“归位”，放回这里。")
                )
                .frame(maxHeight: .infinity)
            } else {
                workspaceSelector

                if let workspace = selectedWorkspace {
                    selectedWorkspaceContent(workspace)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var workspaceSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(dockedWorkspaces) { workspace in
                    let selected = workspace.id == selectedWorkspace?.id
                    Button {
                        selectedWorkspaceID = workspace.id
                        state.selectedFloatingWorkspaceID = workspace.id
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: workspace.symbol)
                                .foregroundStyle(color(for: workspace))
                            Text(workspace.name)
                                .lineLimit(1)
                            Circle()
                                .fill(state.isWorkspaceActive(workspace.id) ? Color.foldeskGreen : Color.secondary.opacity(0.35))
                                .frame(width: 6, height: 6)
                        }
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(selected ? color(for: workspace).opacity(0.10) : Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(selected ? color(for: workspace).opacity(0.65) : Color.panelBorder)
                        )
                    }
                    .buttonStyle(.plain)
                    .offset(workspaceTabDragOffsets[workspace.id] ?? .zero)
                    .zIndex(workspaceTabDragOffsets[workspace.id] == nil ? 0 : 1)
                    .simultaneousGesture(workspaceDetachGesture(for: workspace))
                    .help("点击切换；向外拖动可拆成独立悬浮窗")
                }
            }
        }
    }

    private func selectedWorkspaceContent(_ workspace: WorkspaceItem) -> some View {
        let active = state.isWorkspaceActive(workspace.id)
        return VStack(spacing: 11) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color(for: workspace).opacity(0.12))
                    Image(systemName: workspace.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(color(for: workspace))
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(.headline)
                    Text(workspaceSummary(workspace))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(active ? "使用中" : "未打开", systemImage: active ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(active ? Color.foldeskGreen : .secondary)
            }

            WorkspaceControlList(workspace: workspace, compact: true)
                .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 10) {
                if active {
                    Button("打开全部") {
                        state.openAllWorkspaceMembers(in: workspace.id)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("退出工作区") {
                        state.endWorkspace(workspace.id)
                    }
                    .foregroundStyle(Color.foldeskRed)
                } else {
                    Button {
                        state.openWorkspace(workspace)
                    } label: {
                        Label("进入工作区", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()

                Button("管理工作区") {
                    openMain(.workspaces)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.panelBorder))
    }

    private var toolbarBackground: some ShapeStyle {
        colorScheme == .dark
            ? AnyShapeStyle(.thickMaterial)
            : AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.98))
    }

    private var panelBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.105, blue: 0.115).opacity(0.98)
            : Color(nsColor: .windowBackgroundColor).opacity(0.985)
    }

    private func selectInitialWorkspace() {
        if selectedWorkspaceID == nil ||
            selectedWorkspaceID.map(state.detachedWorkspaceIDs.contains) == true {
            selectedWorkspaceID =
                state.selectedFloatingWorkspaceID ??
                state.activeWorkspaceIDs.first ??
                dockedWorkspaces.first?.id
        }
    }

    private func selectWorkspace(_ workspace: WorkspaceItem) {
        selectedWorkspaceID = workspace.id
        state.selectedFloatingWorkspaceID = workspace.id
        selectedPage = .workspaces
    }

    private func workspaceDetachGesture(for workspace: WorkspaceItem) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                workspaceTabDragOffsets[workspace.id] = value.translation
            }
            .onEnded { value in
                workspaceTabDragOffsets.removeValue(forKey: workspace.id)
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                guard vertical > 24 || horizontal > 80 else { return }
                state.detachWorkspacePanel(workspace.id, near: NSEvent.mouseLocation)
                if selectedWorkspaceID == workspace.id {
                    selectedWorkspaceID = dockedWorkspaces.first?.id
                }
            }
    }

    private func openMain(_ selection: SidebarItem) {
        state.selection = selection
        state.summonApp()
    }

    private func color(for workspace: WorkspaceItem) -> Color {
        switch workspace.colorName {
        case "purple": .purple
        case "orange": .orange
        case "green": .green
        default: .foldeskBlue
        }
    }

    private func windowStatus(_ entry: FloatingWindowEntry) -> String {
        if entry.window.isMinimized { return "已最小化" }
        if entry.application.isActive { return "前台" }
        return "可见"
    }

    private func windowStatusColor(_ entry: FloatingWindowEntry) -> Color {
        if entry.window.isMinimized { return .secondary }
        if entry.application.isActive { return .foldeskBlue }
        return .foldeskGreen
    }

    private func workspaceSummary(_ workspace: WorkspaceItem) -> String {
        let runningMembers = workspace.memberApplications.filter {
            state.runningApplication(for: $0) != nil
        }
        let windows = runningMembers.reduce(0) { result, member in
            result + (state.runningApplication(for: member)?.windows.count ?? 0)
        }
        return "\(runningMembers.count)/\(workspace.applicationCount) 个应用运行 · \(windows) 个窗口"
    }
}

private struct FloatingPopoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
