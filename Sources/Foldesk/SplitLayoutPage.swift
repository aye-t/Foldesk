import AppKit
import SwiftUI

private enum SplitTemplate: String, CaseIterable, Identifiable {
    case halves = "左右分屏"
    case leading = "左大右小"
    case stacked = "上下分屏"
    case columns = "三栏布局"
    case focus = "左一右二"
    case grid = "四宫格"
    case custom = "自定义"

    var id: String { rawValue }
}

private struct LayoutRegion: Identifiable, Hashable {
    let id: UUID
    var rect: CGRect

    init(id: UUID = UUID(), rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

private struct LayoutSnapshot {
    let template: SplitTemplate
    let regions: [LayoutRegion]
    let assignments: [UUID: String]
    let xRatio: CGFloat
    let xRatio2: CGFloat
    let yRatio: CGFloat
    let spacing: CGFloat
}

private struct SavedLayoutTemplate: Codable, Identifiable {
    struct SavedRegion: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var rect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    let id: UUID
    let name: String
    let regions: [SavedRegion]
    let spacing: Double
}

struct SplitLayoutPage: View {
    @EnvironmentObject private var state: AppState

    @State private var template: SplitTemplate = .halves
    @State private var regions: [LayoutRegion] = []
    @State private var assignments: [UUID: String] = [:]
    @State private var selectedRegionID: UUID?
    @State private var xRatio: CGFloat = 0.5
    @State private var xRatio2: CGFloat = 0.67
    @State private var yRatio: CGFloat = 0.5
    @State private var spacing: CGFloat = 8
    @State private var history: [LayoutSnapshot] = []
    @State private var dividerDragSnapshotTaken = false
    @State private var previewFrames: [String: CGRect] = [:]
    @State private var showSaveTemplate = false
    @State private var templateName = ""
    @State private var savedTemplates: [SavedLayoutTemplate] = []
    @State private var layoutDropTargeted = false

    private let savedTemplatesKey = "foldesk.split-layout.templates.v1"

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "分屏布局",
                subtitle: "自定义屏幕版式，将窗口拖入区域并一键应用",
                searchable: true
            )

            templateSection
                .padding(.horizontal, 20)

            HStack(alignment: .top, spacing: 16) {
                previewSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                windowSection
                    .frame(width: 250)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 78)
        }
        .overlay(alignment: .bottom) {
            splitBottomBar
                .padding(.bottom, 14)
        }
        .overlay(alignment: .top) {
            if !previewFrames.isEmpty {
                previewConfirmation
                    .padding(.top, 84)
            }
        }
        .onAppear {
            loadSavedTemplates()
            if regions.isEmpty { selectTemplate(.halves, recordHistory: false) }
        }
        .alert("保存布局模板", isPresented: $showSaveTemplate) {
            TextField("例如：论文写作", text: $templateName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                saveCurrentTemplate()
            }
        } message: {
            Text("只保存区域比例和窗口间距，不保存具体窗口。")
        }
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                stepTitle(1, "选择布局模板")
                Spacer()
                if !savedTemplates.isEmpty {
                    Menu {
                        ForEach(savedTemplates) { saved in
                            Button(saved.name) { selectSavedTemplate(saved) }
                        }
                        Divider()
                        Button("清除已保存模板", role: .destructive) {
                            savedTemplates.removeAll()
                            persistSavedTemplates()
                        }
                    } label: {
                        Label("已保存 \(savedTemplates.count)", systemImage: "bookmark")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            HStack(spacing: 10) {
                ForEach(SplitTemplate.allCases) { item in
                    Button {
                        selectTemplate(item)
                    } label: {
                        VStack(spacing: 7) {
                            TemplateGlyph(template: item)
                                .frame(height: 45)
                            Text(item.rawValue)
                                .font(.system(size: 11.5, weight: template == item ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .foregroundStyle(template == item ? Color.foldeskBlue : Color.primary)
                        .background(template == item ? Color.foldeskBlue.opacity(0.07) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(template == item ? Color.foldeskBlue : Color.panelBorder, lineWidth: template == item ? 1.6 : 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                stepTitle(2, "屏幕布局预览")
                Spacer()
                Label(NSScreen.main?.localizedName ?? "当前主显示器", systemImage: "display")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("窗口间距", selection: $spacing) {
                    ForEach([0, 4, 8, 12, 16], id: \.self) { value in
                        Text("\(value) px").tag(CGFloat(value))
                    }
                }
                .labelsHidden()
                .frame(width: 82)
                .onChange(of: spacing) { oldValue, _ in
                    pushHistory(overridingSpacing: oldValue)
                }
            }

            GeometryReader { proxy in
                let displaySize = fittedDisplaySize(in: proxy.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.black.opacity(0.88))
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
                    layoutCanvas
                        .padding(10)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .frame(minHeight: 300)

            HStack {
                Label("拖动分隔线调整比例；拖入窗口后可自动交换", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if template == .custom, let selectedRegionID {
                    customToolbar(regionID: selectedRegionID)
                }
            }
        }
        .padding(14)
        .background(panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var layoutCanvas: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)
                ForEach(regions) { region in
                    regionView(region, in: proxy.size)
                }
                if template != .custom {
                    dividerHandles(in: proxy.size)
                }
            }
            .coordinateSpace(name: "layoutCanvas")
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, location in
                guard let windowID = items.first,
                      let target = region(at: location, in: proxy.size) else {
                    return false
                }
                assign(windowID: windowID, to: target.id)
                return true
            } isTargeted: { targeted in
                layoutDropTargeted = targeted
            }
            .overlay {
                if layoutDropTargeted {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.foldeskBlue, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func regionView(_ region: LayoutRegion, in size: CGSize) -> some View {
        let frame = pixelFrame(region.rect, in: size)
        let window = assignedWindow(region.id)
        let selected = selectedRegionID == region.id

        return ZStack {
            LinearGradient(
                colors: [Color.foldeskBlue.opacity(window == nil ? 0.035 : 0.075), Color.mint.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let window {
                VStack(spacing: 7) {
                    AppIcon(image: icon(for: window), size: 32)
                    Text(window.appName).font(.system(size: 13, weight: .semibold))
                    Text(window.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("移除") {
                        pushHistory()
                        assignments[region.id] = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .padding(8)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(Color.foldeskBlue)
                    Text("区域 \(regionNumber(region.id))").font(.caption.weight(.semibold))
                    Text("将窗口拖到这里").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: max(1, frame.width - 3), height: max(1, frame.height - 3))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? Color.foldeskBlue : Color.foldeskBlue.opacity(0.35), lineWidth: selected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .position(x: frame.midX, y: frame.midY)
        .contentShape(Rectangle())
        .onTapGesture { selectedRegionID = region.id }
    }

    @ViewBuilder
    private func dividerHandles(in size: CGSize) -> some View {
        let handleWidth: CGFloat = 16
        if template != .stacked {
            dividerHandle(vertical: true)
                .frame(width: handleWidth, height: size.height)
                .position(x: xRatio * size.width, y: size.height / 2)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("layoutCanvas"))
                        .onChanged {
                            beginDividerDrag()
                            xRatio = clamp($0.location.x / size.width)
                            rebuildStandardRegions()
                        }
                        .onEnded { _ in dividerDragSnapshotTaken = false }
                )
        }
        if template == .columns {
            dividerHandle(vertical: true)
                .frame(width: handleWidth, height: size.height)
                .position(x: xRatio2 * size.width, y: size.height / 2)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("layoutCanvas"))
                        .onChanged {
                            beginDividerDrag()
                            xRatio2 = min(0.85, max(xRatio + 0.15, $0.location.x / size.width))
                            rebuildStandardRegions()
                        }
                        .onEnded { _ in dividerDragSnapshotTaken = false }
                )
        }
        if [.stacked, .focus, .grid].contains(template) {
            dividerHandle(vertical: false)
                .frame(width: template == .focus ? size.width * (1 - xRatio) : size.width, height: handleWidth)
                .position(
                    x: template == .focus ? (xRatio + (1 - xRatio) / 2) * size.width : size.width / 2,
                    y: yRatio * size.height
                )
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("layoutCanvas"))
                        .onChanged {
                            beginDividerDrag()
                            yRatio = clamp($0.location.y / size.height)
                            rebuildStandardRegions()
                        }
                        .onEnded { _ in dividerDragSnapshotTaken = false }
                )
        }
    }

    private func dividerHandle(vertical: Bool) -> some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.white)
                .frame(width: vertical ? 14 : 32, height: vertical ? 32 : 14)
                .overlay(Image(systemName: vertical ? "ellipsis" : "ellipsis").font(.caption2))
                .overlay(Capsule().stroke(Color.panelBorder))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
    }

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle(3, "当前窗口")
            Text("拖动具体窗口到布局区域")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(state.filteredApplications) { app in
                        ForEach(app.windows) { window in
                            windowRow(window, icon: app.icon)
                        }
                    }
                    if state.windowCount == 0 {
                        EmptyState(symbol: "macwindow", title: "没有可用窗口", message: "请先打开应用窗口，再点击刷新。")
                            .frame(height: 210)
                    }
                }
            }

            Divider()
            Label("拖动窗口到布局区域，确认后自动排列", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ActionButton(title: "应用布局", symbol: "rectangle.3.group.fill", prominent: true) {
                applyLayout()
            }
            ActionButton(title: "预览布局", symbol: "eye") {
                previewLayout()
            }
            ActionButton(title: "保存为模板", symbol: "square.and.arrow.down") {
                showSaveTemplate = true
            }
        }
        .padding(14)
        .background(panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private func windowRow(_ window: WindowItem, icon: NSImage) -> some View {
        let region = assignments.first(where: { $0.value == window.id }).map(\.key)
        return HStack(spacing: 9) {
            AppIcon(image: icon, size: 27)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.appName).font(.caption.weight(.semibold)).lineLimit(1)
                Text(window.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let region {
                Text("区域 \(regionNumber(region))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.foldeskBlue)
            }
            Button {
                assignToNextRegion(windowID: window.id)
            } label: {
                Image(systemName: "arrow.left.to.line")
            }
            .buttonStyle(.borderless)
            .help("放入选中或下一个空白区域")
            Image(systemName: "circle.grid.3x3.fill")
                .foregroundStyle(.tertiary)
        }
        .padding(9)
        .background(region == nil ? Color.primary.opacity(0.025) : Color.foldeskBlue.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .draggable(window.id)
    }

    private func region(at location: CGPoint, in size: CGSize) -> LayoutRegion? {
        guard size.width > 0, size.height > 0 else { return nil }
        let normalized = CGPoint(x: location.x / size.width, y: location.y / size.height)
        return regions.first {
            $0.rect.insetBy(dx: -0.002, dy: -0.002).contains(normalized)
        }
    }

    private func assignToNextRegion(windowID: String) {
        let selected = selectedRegionID.flatMap { id in
            regions.first(where: { $0.id == id && assignments[$0.id] == nil })
        }
        let target = selected ??
            regions.first(where: { assignments[$0.id] == nil }) ??
            selectedRegionID.flatMap { id in regions.first(where: { $0.id == id }) } ??
            regions.first
        guard let target else { return }
        assign(windowID: windowID, to: target.id)
    }

    private var splitBottomBar: some View {
        HStack(spacing: 10) {
            Button { resetLayout() } label: {
                Label("重置布局", systemImage: "arrow.counterclockwise").frame(width: 150)
            }
            Button { undo() } label: {
                Label("撤销", systemImage: "arrow.uturn.backward").frame(width: 150)
            }
            .disabled(history.isEmpty)
            Button {
                applyLayout()
                state.beginCreatingWorkspace()
            } label: {
                Label("保存为工作区", systemImage: "folder.badge.plus").frame(width: 170)
            }
            Button { applyLayout() } label: {
                Label("应用布局", systemImage: "rectangle.3.group.fill").frame(width: 170)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.foldeskBlue)
            .disabled(assignments.isEmpty)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(8)
        .background(.regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 7)
    }

    private var previewConfirmation: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.circle.fill").foregroundStyle(Color.foldeskBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在预览真实窗口布局").font(.headline)
                Text("确认效果，或恢复预览前的位置").font(.caption).foregroundStyle(.secondary)
            }
            Button("保持布局") {
                previewFrames.removeAll()
                state.toast = "已保持当前布局"
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.foldeskBlue)
            Button("恢复原状") { restorePreview() }
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.panelBorder))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
    }

    private func customToolbar(regionID: UUID) -> some View {
        HStack(spacing: 5) {
            Button("纵向拆分") { splitCustom(regionID, vertically: true) }
            Button("横向拆分") { splitCustom(regionID, vertically: false) }
            Button("删除", role: .destructive) { deleteCustom(regionID) }
                .disabled(regions.count <= 1)
        }
        .controlSize(.small)
    }

    private func stepTitle(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(Color.foldeskBlue)
                .clipShape(Circle())
            Text(title).font(.system(size: 14, weight: .semibold))
        }
    }

    private var panelBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.48)
    }

    private func selectTemplate(_ item: SplitTemplate, recordHistory: Bool = true) {
        if recordHistory, !regions.isEmpty { pushHistory() }
        template = item
        assignments.removeAll()
        selectedRegionID = nil
        switch item {
        case .halves:
            xRatio = 0.5; yRatio = 0.5
        case .leading:
            xRatio = 0.65; yRatio = 0.5
        case .stacked:
            xRatio = 0.5; yRatio = 0.5
        case .columns:
            xRatio = 1 / 3; xRatio2 = 2 / 3; yRatio = 0.5
        case .focus:
            xRatio = 0.62; yRatio = 0.5
        case .grid:
            xRatio = 0.5; yRatio = 0.5
        case .custom:
            regions = [LayoutRegion(rect: CGRect(x: 0, y: 0, width: 1, height: 1))]
            selectedRegionID = regions.first?.id
            return
        }
        rebuildStandardRegions()
    }

    private func rebuildStandardRegions() {
        let oldWindows = regions.enumerated().compactMap { index, region in
            assignments[region.id].map { (index, $0) }
        }
        let rects: [CGRect]
        switch template {
        case .halves, .leading:
            rects = [
                CGRect(x: 0, y: 0, width: xRatio, height: 1),
                CGRect(x: xRatio, y: 0, width: 1 - xRatio, height: 1)
            ]
        case .stacked:
            rects = [
                CGRect(x: 0, y: 0, width: 1, height: yRatio),
                CGRect(x: 0, y: yRatio, width: 1, height: 1 - yRatio)
            ]
        case .columns:
            rects = [
                CGRect(x: 0, y: 0, width: xRatio, height: 1),
                CGRect(x: xRatio, y: 0, width: xRatio2 - xRatio, height: 1),
                CGRect(x: xRatio2, y: 0, width: 1 - xRatio2, height: 1)
            ]
        case .focus:
            rects = [
                CGRect(x: 0, y: 0, width: xRatio, height: 1),
                CGRect(x: xRatio, y: 0, width: 1 - xRatio, height: yRatio),
                CGRect(x: xRatio, y: yRatio, width: 1 - xRatio, height: 1 - yRatio)
            ]
        case .grid:
            rects = [
                CGRect(x: 0, y: 0, width: xRatio, height: yRatio),
                CGRect(x: xRatio, y: 0, width: 1 - xRatio, height: yRatio),
                CGRect(x: 0, y: yRatio, width: xRatio, height: 1 - yRatio),
                CGRect(x: xRatio, y: yRatio, width: 1 - xRatio, height: 1 - yRatio)
            ]
        case .custom:
            return
        }
        regions = rects.map { LayoutRegion(rect: $0) }
        assignments.removeAll()
        for (index, windowID) in oldWindows where regions.indices.contains(index) {
            assignments[regions[index].id] = windowID
        }
    }

    private func assign(windowID: String, to targetID: UUID) {
        guard state.applications.flatMap(\.windows).contains(where: { $0.id == windowID }) else { return }
        pushHistory()
        let sourceID = assignments.first(where: { $0.value == windowID })?.key
        let displaced = assignments[targetID]
        assignments[targetID] = windowID
        if let sourceID, sourceID != targetID {
            assignments[sourceID] = displaced
        } else if sourceID == nil, let displaced {
            assignments = assignments.filter { $0.value != displaced || $0.key == targetID }
        }
        selectedRegionID = targetID
    }

    private func splitCustom(_ id: UUID, vertically: Bool) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        pushHistory()
        let original = regions[index]
        let first: CGRect
        let second: CGRect
        if vertically {
            first = CGRect(x: original.rect.minX, y: original.rect.minY, width: original.rect.width / 2, height: original.rect.height)
            second = CGRect(x: original.rect.midX, y: original.rect.minY, width: original.rect.width / 2, height: original.rect.height)
        } else {
            first = CGRect(x: original.rect.minX, y: original.rect.minY, width: original.rect.width, height: original.rect.height / 2)
            second = CGRect(x: original.rect.minX, y: original.rect.midY, width: original.rect.width, height: original.rect.height / 2)
        }
        regions[index].rect = first
        let newRegion = LayoutRegion(rect: second)
        regions.insert(newRegion, at: index + 1)
        selectedRegionID = newRegion.id
    }

    private func deleteCustom(_ id: UUID) {
        guard regions.count > 1,
              let removed = regions.first(where: { $0.id == id }),
              let neighborIndex = bestNeighborIndex(for: removed) else { return }
        pushHistory()
        let neighborID = regions[neighborIndex].id
        regions[neighborIndex].rect = regions[neighborIndex].rect.union(removed.rect)
        regions.removeAll { $0.id == id }
        assignments[id] = nil
        selectedRegionID = neighborID
    }

    private func bestNeighborIndex(for removed: LayoutRegion) -> Int? {
        regions.indices
            .filter { regions[$0].id != removed.id }
            .max { sharedEdge(regions[$0].rect, removed.rect) < sharedEdge(regions[$1].rect, removed.rect) }
    }

    private func sharedEdge(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let epsilon: CGFloat = 0.001
        if abs(a.maxX - b.minX) < epsilon || abs(b.maxX - a.minX) < epsilon {
            return max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        }
        if abs(a.maxY - b.minY) < epsilon || abs(b.maxY - a.minY) < epsilon {
            return max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        }
        return 0
    }

    private func applyLayout(showToast: Bool = true) {
        guard state.accessibilityGranted else {
            state.toast = "请先在设置中开启辅助功能权限"
            return
        }
        var succeeded = 0
        for region in regions {
            guard let window = assignedWindow(region.id) else { continue }
            if state.manager.place(window, normalizedRect: region.rect, spacing: spacing) {
                succeeded += 1
            }
        }
        if showToast {
            state.toast = succeeded == assignments.count
                ? "布局已应用，成功排列 \(succeeded) 个窗口"
                : "布局已部分应用：成功 \(succeeded)/\(assignments.count) 个窗口"
        }
    }

    private func previewLayout() {
        previewFrames = Dictionary(
            uniqueKeysWithValues: assignedWindows.map { ($0.id, $0.frame) }
        )
        guard !previewFrames.isEmpty else {
            state.toast = "请先把窗口拖入布局区域"
            return
        }
        applyLayout(showToast: false)
    }

    private func restorePreview() {
        for window in assignedWindows {
            if let frame = previewFrames[window.id] {
                _ = state.manager.restoreFrame(window, frame: frame)
            }
        }
        previewFrames.removeAll()
        state.toast = "已恢复预览前的位置"
    }

    private func resetLayout() {
        pushHistory()
        selectTemplate(template, recordHistory: false)
        state.toast = "已恢复模板默认比例"
    }

    private func saveCurrentTemplate() {
        let trimmed = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedLayoutTemplate(
            id: UUID(),
            name: trimmed.isEmpty ? template.rawValue : trimmed,
            regions: regions.map {
                SavedLayoutTemplate.SavedRegion(
                    x: $0.rect.minX,
                    y: $0.rect.minY,
                    width: $0.rect.width,
                    height: $0.rect.height
                )
            },
            spacing: spacing
        )
        savedTemplates.append(saved)
        persistSavedTemplates()
        state.toast = "布局模板“\(saved.name)”已保存"
        templateName = ""
    }

    private func selectSavedTemplate(_ saved: SavedLayoutTemplate) {
        pushHistory()
        template = .custom
        regions = saved.regions.map { LayoutRegion(rect: $0.rect) }
        spacing = saved.spacing
        assignments.removeAll()
        selectedRegionID = regions.first?.id
    }

    private func loadSavedTemplates() {
        guard let data = UserDefaults.standard.data(forKey: savedTemplatesKey),
              let decoded = try? JSONDecoder().decode([SavedLayoutTemplate].self, from: data) else { return }
        savedTemplates = decoded
    }

    private func persistSavedTemplates() {
        guard let data = try? JSONEncoder().encode(savedTemplates) else { return }
        UserDefaults.standard.set(data, forKey: savedTemplatesKey)
    }

    private func pushHistory() {
        history.append(snapshot)
        if history.count > 30 { history.removeFirst() }
    }

    private func pushHistory(overridingSpacing oldSpacing: CGFloat) {
        history.append(
            LayoutSnapshot(
                template: template,
                regions: regions,
                assignments: assignments,
                xRatio: xRatio,
                xRatio2: xRatio2,
                yRatio: yRatio,
                spacing: oldSpacing
            )
        )
        if history.count > 30 { history.removeFirst() }
    }

    private func beginDividerDrag() {
        guard !dividerDragSnapshotTaken else { return }
        pushHistory()
        dividerDragSnapshotTaken = true
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        template = previous.template
        regions = previous.regions
        assignments = previous.assignments
        xRatio = previous.xRatio
        xRatio2 = previous.xRatio2
        yRatio = previous.yRatio
        spacing = previous.spacing
        selectedRegionID = nil
    }

    private var snapshot: LayoutSnapshot {
        LayoutSnapshot(
            template: template,
            regions: regions,
            assignments: assignments,
            xRatio: xRatio,
            xRatio2: xRatio2,
            yRatio: yRatio,
            spacing: spacing
        )
    }

    private var assignedWindows: [WindowItem] {
        regions.compactMap { assignedWindow($0.id) }
    }

    private func assignedWindow(_ regionID: UUID) -> WindowItem? {
        guard let id = assignments[regionID] else { return nil }
        return state.applications.flatMap(\.windows).first { $0.id == id }
    }

    private func icon(for window: WindowItem) -> NSImage {
        state.applications.first(where: { $0.pid == window.pid })?.icon
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }

    private func regionNumber(_ id: UUID) -> Int {
        (regions.firstIndex(where: { $0.id == id }) ?? 0) + 1
    }

    private func fittedDisplaySize(in available: CGSize) -> CGSize {
        let width = min(available.width - 14, (available.height - 12) * 16 / 10)
        return CGSize(width: max(260, width), height: max(180, width * 10 / 16))
    }

    private func pixelFrame(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width,
            y: normalized.minY * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(0.8, max(0.2, value))
    }
}

private struct TemplateGlyph: View {
    let template: SplitTemplate

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.foldeskBlue.opacity(0.055))
                Path { path in
                    switch template {
                    case .halves:
                        path.move(to: CGPoint(x: w / 2, y: 0)); path.addLine(to: CGPoint(x: w / 2, y: h))
                    case .leading:
                        path.move(to: CGPoint(x: w * 0.65, y: 0)); path.addLine(to: CGPoint(x: w * 0.65, y: h))
                    case .stacked:
                        path.move(to: CGPoint(x: 0, y: h / 2)); path.addLine(to: CGPoint(x: w, y: h / 2))
                    case .columns:
                        for x in [w / 3, w * 2 / 3] {
                            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                        }
                    case .focus:
                        path.move(to: CGPoint(x: w * 0.62, y: 0)); path.addLine(to: CGPoint(x: w * 0.62, y: h))
                        path.move(to: CGPoint(x: w * 0.62, y: h / 2)); path.addLine(to: CGPoint(x: w, y: h / 2))
                    case .grid:
                        path.move(to: CGPoint(x: w / 2, y: 0)); path.addLine(to: CGPoint(x: w / 2, y: h))
                        path.move(to: CGPoint(x: 0, y: h / 2)); path.addLine(to: CGPoint(x: w, y: h / 2))
                    case .custom:
                        break
                    }
                }
                .stroke(Color.foldeskBlue.opacity(0.55), lineWidth: 1)
                if template == .custom {
                    Image(systemName: "plus").font(.title3).foregroundStyle(Color.foldeskBlue)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.foldeskBlue.opacity(0.38)))
        }
    }
}
