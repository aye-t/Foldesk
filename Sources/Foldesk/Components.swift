import AppKit
import SwiftUI

extension Color {
    static let foldeskBlue = Color(red: 0.06, green: 0.40, blue: 0.95)
    static let foldeskRed = Color(red: 0.95, green: 0.27, blue: 0.20)
    static let foldeskGreen = Color(red: 0.20, green: 0.70, blue: 0.30)
    static let foldeskOrange = Color(red: 0.95, green: 0.60, blue: 0.10)
    static let panelBorder = Color.primary.opacity(0.09)
}

extension NSImage {
    static var foldeskBrandIcon: NSImage {
        // SwiftPM 资源（swift run / Xcode）：优先从 module bundle 取
        if let url = Bundle.module.url(forResource: "FoldeskIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // 打包产物（build-app.sh 复制到 Contents/Resources）：从 main bundle 取
        if let url = Bundle.main.url(forResource: "FoldeskIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "rectangle.3.group.fill", accessibilityDescription: "Foldesk")!
    }
}

struct AppIcon: View {
    let image: NSImage
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

/// Native application control used inside the floating panel.
/// Keeping both drawing and hit testing in the same NSView avoids SwiftUI's
/// ScrollView consuming click-through events before they reach the action.
struct FirstMouseApplicationButton: NSViewRepresentable {
    let image: NSImage
    let title: String
    let subtitle: String
    let subtitleColor: NSColor
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> FirstMouseApplicationView {
        let view = FirstMouseApplicationView(frame: .zero)
        view.coordinator = context.coordinator
        configure(view)
        return view
    }

    func updateNSView(_ nsView: FirstMouseApplicationView, context: Context) {
        context.coordinator.action = action
        nsView.coordinator = context.coordinator
        configure(nsView)
    }

    private func configure(_ view: FirstMouseApplicationView) {
        let icon = (image.copy() as? NSImage) ?? image
        icon.size = NSSize(width: 23, height: 23)
        view.image = icon
        view.title = title
        view.subtitle = subtitle
        view.subtitleColor = subtitleColor
        view.needsDisplay = true
        view.setAccessibilityLabel("显示并切换到 \(title)")
        view.setAccessibilityHelp(subtitle)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func performAction() {
            action()
        }
    }

    final class FirstMouseApplicationView: NSView {
        weak var coordinator: Coordinator?
        private var mouseMonitor: Any?
        var image: NSImage?
        var title = ""
        var subtitle = ""
        var subtitleColor: NSColor = .secondaryLabelColor

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMouseMonitor()
            } else if mouseMonitor == nil {
                mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                    [weak self] event in
                    guard let self,
                          event.window === self.window,
                          self.bounds.contains(
                              self.convert(event.locationInWindow, from: nil)
                          ) else {
                        return event
                    }
                    self.coordinator?.performAction()
                    return nil
                }
            }
        }

        private func removeMouseMonitor() {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let iconSize: CGFloat = 23
            image?.draw(
                in: NSRect(
                    x: 0,
                    y: (bounds.height - iconSize) / 2,
                    width: iconSize,
                    height: iconSize
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            let textX = iconSize + 8
            let textWidth = max(0, bounds.width - textX)
            (title as NSString).draw(
                in: NSRect(x: textX, y: bounds.midY, width: textWidth, height: 15),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.labelColor
                ]
            )
            (subtitle as NSString).draw(
                in: NSRect(x: textX, y: bounds.midY - 14, width: textWidth, height: 14),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: subtitleColor
                ]
            )
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            coordinator?.performAction()
        }

        override func accessibilityPerformPress() -> Bool {
            coordinator?.performAction()
            return true
        }
    }
}

struct ActionButton: View {
    let title: String
    let symbol: String
    var role: ButtonRole?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Color.white : (role == .destructive ? Color.foldeskRed : Color.primary))
        .background(prominent ? Color.foldeskBlue : Color.primary.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(prominent ? Color.foldeskBlue : (role == .destructive ? Color.foldeskRed.opacity(0.35) : Color.panelBorder))
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct WindowThumbnail: View {
    @EnvironmentObject private var state: AppState
    let window: WindowItem
    let icon: NSImage
    let selected: Bool
    let action: () -> Void
    @State private var preview: NSImage?

    private var accent: Color {
        let palette: [Color] = [.blue, .indigo, .mint, .orange, .purple]
        return palette[abs(window.title.hashValue) % palette.count]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(
                            LinearGradient(
                                colors: [Color(nsColor: .windowBackgroundColor), accent.opacity(0.10)],
                                startPoint: .top,
                                endPoint: .bottomTrailing
                            )
                        )
                    if let preview {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        VStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Circle().fill(.red.opacity(0.7)).frame(width: 5, height: 5)
                                Circle().fill(.yellow.opacity(0.8)).frame(width: 5, height: 5)
                                Circle().fill(.green.opacity(0.7)).frame(width: 5, height: 5)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            AppIcon(image: icon, size: 25)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(accent.opacity(0.17))
                                .frame(width: 62, height: 5)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.07))
                                .frame(width: 82, height: 4)
                        }
                        .padding(7)
                    }
                    if selected {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.white, Color.foldeskBlue)
                                    .padding(6)
                            }
                            Spacer()
                        }
                    }
                    HStack(spacing: 5) {
                        TrafficLightButton(color: .red, symbol: "xmark", help: "关闭窗口（应用仍运行）") {
                            state.manager.close(window)
                        }
                        TrafficLightButton(color: .yellow, symbol: "minus", help: "最小化窗口") {
                            state.manager.minimize(window)
                        }
                        TrafficLightButton(color: .green, symbol: "arrow.up.left.and.arrow.down.right", help: "放大或全屏") {
                            state.manager.toggleZoom(window)
                        }
                    }
                    .padding(7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(5)
            }
            .frame(height: 83)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.foldeskBlue : Color.panelBorder, lineWidth: selected ? 2 : 1)
            )

            Text(window.title)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 6)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help("点击选择，双击可切换至窗口")
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            NotificationCenter.default.post(name: .focusWindow, object: window)
        })
        .task(id: "\(window.cgWindowID ?? 0)-\(state.screenRecordingGranted)") {
            guard state.screenRecordingGranted, let windowID = window.cgWindowID else {
                preview = nil
                return
            }
            preview = await state.manager.capturePreview(windowID: windowID)
        }
    }
}

private struct TrafficLightButton: View {
    let color: Color
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color)
                Image(systemName: symbol)
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(.black.opacity(0.58))
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension Notification.Name {
    static let focusWindow = Notification.Name("foldesk.focusWindow")
}

@MainActor
enum WindowFrameGuard {
    static func constrain(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let visibleFrame = bestVisibleFrame(for: window.frame) else { return }

        var frame = window.frame
        frame.size.width = min(max(frame.width, window.minSize.width), visibleFrame.width)
        frame.size.height = min(max(frame.height, window.minSize.height), visibleFrame.height)
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)

        if !approximatelyEqual(frame, window.frame) {
            window.setFrame(frame, display: true)
        }
    }

    private static func bestVisibleFrame(for frame: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        return screens.max { lhs, rhs in
            intersectionArea(frame, lhs.visibleFrame) < intersectionArea(frame, rhs.visibleFrame)
        }?.visibleFrame
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5 &&
            abs(lhs.minY - rhs.minY) < 0.5 &&
            abs(lhs.width - rhs.width) < 0.5 &&
            abs(lhs.height - rhs.height) < 0.5
    }
}

struct WindowZoomBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ZoomEventView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ZoomEventView: NSView {
        private static var normalFrames: [Int: CGRect] = [:]
        private var eventMonitor: Any?
        private var screenObserver: NSObjectProtocol?
        private weak var hostWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hostWindow = window
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.hostWindow else { return }
                WindowFrameGuard.constrain(window)
            }
            if screenObserver == nil {
                screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let window = self?.hostWindow else { return }
                        WindowFrameGuard.constrain(window)
                    }
                }
            }
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      event.clickCount == 2,
                      let window = self.hostWindow,
                      event.window === window,
                      self.isTitleBarDoubleClick(event, in: window) else {
                    return event
                }
                self.toggleZoom(window)
                return nil
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            if newWindow == nil, let screenObserver {
                NotificationCenter.default.removeObserver(screenObserver)
                self.screenObserver = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func isTitleBarDoubleClick(_ event: NSEvent, in window: NSWindow) -> Bool {
            // unified 标题栏下 SwiftUI 可能把 contentLayoutRect 延伸至窗口顶端，
            // 因而不能依赖 contentLayoutRect.maxY 判断标题栏。AppKit 的窗口坐标
            // 原点在左下角，直接取顶部 64 pt 能稳定覆盖标题栏和紧凑工具栏。
            let isInTopBar = event.locationInWindow.y >= window.frame.height - 64
            // 排除左上角交通灯和侧边栏按钮区域，避免操作按钮时误触发。
            return isInTopBar && event.locationInWindow.x > 140
        }

        private func toggleZoom(_ window: NSWindow) {
            let key = window.windowNumber
            guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
                return
            }

            if let normalFrame = Self.normalFrames.removeValue(forKey: key) {
                window.setFrame(
                    centeredFrame(for: normalFrame.size, in: visibleFrame),
                    display: true,
                    animate: true
                )
                return
            }

            let normalFrame = preferredNormalFrame(
                minimumSize: window.minSize,
                in: visibleFrame
            )

            // 状态可能因窗口或视图重建而丢失。此时若窗口已经占满工作区，
            // 双击应直接回到居中的常规尺寸，而不是再次执行“放大”。
            if isZoomed(window.frame, in: visibleFrame) {
                window.setFrame(normalFrame, display: true, animate: true)
                return
            }

            Self.normalFrames[key] = normalFrame
            window.setFrame(visibleFrame, display: true, animate: true)
        }

        private func isZoomed(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
            let tolerance: CGFloat = 12
            return abs(frame.minX - visibleFrame.minX) <= tolerance &&
                abs(frame.minY - visibleFrame.minY) <= tolerance &&
                abs(frame.width - visibleFrame.width) <= tolerance &&
                abs(frame.height - visibleFrame.height) <= tolerance
        }

        private func preferredNormalFrame(
            minimumSize: CGSize,
            in visibleFrame: CGRect
        ) -> CGRect {
            let requestedSize = CGSize(
                width: visibleFrame.width * 0.55,
                height: visibleFrame.height * 0.55
            )
            let size = CGSize(
                width: min(
                    visibleFrame.width,
                    max(minimumSize.width, requestedSize.width)
                ),
                height: min(
                    visibleFrame.height,
                    max(minimumSize.height, requestedSize.height)
                )
            )
            return centeredFrame(for: size, in: visibleFrame)
        }

        private func centeredFrame(for size: CGSize, in visibleFrame: CGRect) -> CGRect {
            let fittedSize = CGSize(
                width: min(size.width, visibleFrame.width),
                height: min(size.height, visibleFrame.height)
            )
            return CGRect(
                x: visibleFrame.midX - fittedSize.width / 2,
                y: visibleFrame.midY - fittedSize.height / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.foldeskBlue)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(.primary)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.panelBorder))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}
