import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class WindowManager {
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        openPrivacySettings(pane: "Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        openPrivacySettings(pane: "Privacy_ScreenCapture")
    }

    func scanApplications() -> [RunningAppItem] {
        let fallbackWindows = cgWindowFallback()
        let running = NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      !app.isTerminated else { return false }
                // 常规应用直接纳入；菜单栏/辅助型应用（如百度网盘代理、LSUIElement 应用）
                // 只在确有可见窗口时才纳入，否则会把纯后台助手也列进来造成干扰。
                if app.activationPolicy == .regular { return true }
                if app.activationPolicy == .accessory {
                    return (fallbackWindows[app.processIdentifier]?.isEmpty ?? true) == false
                }
                return false
            }

        return running.compactMap { app in
            let name = app.localizedName ?? app.bundleIdentifier ?? "未知应用"
            let pid = app.processIdentifier
            let windows = hasAccessibilityPermission
                ? axWindows(pid: pid, appName: name, cgWindows: fallbackWindows[pid] ?? [])
                : (fallbackWindows[pid] ?? [])
            return RunningAppItem(
                id: app.bundleIdentifier ?? "\(pid)",
                pid: pid,
                name: name,
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                windows: windows,
                isActive: app.isActive
            )
        }
        .sorted {
            if $0.windows.isEmpty != $1.windows.isEmpty { return !$0.windows.isEmpty }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func focus(_ window: WindowItem) {
        guard let element = findWindow(window) else { return }
        setBool(element, attribute: kAXMinimizedAttribute, value: false)
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate(options: [.activateAllWindows])
        }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func minimize(_ window: WindowItem) {
        guard let element = findWindow(window) else { return }
        setBool(element, attribute: kAXMinimizedAttribute, value: true)
    }

    func toggleZoom(_ window: WindowItem) {
        guard let element = findWindow(window) else { return }
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &button) == .success,
           let button {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            return
        }
        let isFullScreen = boolValue(element, attribute: "AXFullScreen")
        setBool(element, attribute: "AXFullScreen", value: !isFullScreen)
    }

    func close(_ window: WindowItem) {
        guard let element = findWindow(window) else { return }
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
           let button {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// 统一的 AX 窗口解析入口。AppState 的分屏检查与 WindowManager 必须
    /// 命中同一个元素，否则同名窗口会出现“设置 A、校验 B”。
    func accessibilityElement(for window: WindowItem) -> AXUIElement? {
        findWindow(window)
    }

    /// 把窗口移动到主显示器可用区域中的归一化矩形（含置顶）。归一化坐标原点位于左上角。
    @discardableResult
    func place(_ window: WindowItem, normalizedRect: CGRect, spacing: CGFloat) -> Bool {
        guard hasAccessibilityPermission,
              let element = findWindow(window),
              let screen = NSScreen.main else { return false }

        let visible = screen.visibleFrame
        let inset = max(0, spacing / 2)
        let cocoaRect = CGRect(
            x: visible.minX + normalizedRect.minX * visible.width + inset,
            y: visible.minY + (1 - normalizedRect.maxY) * visible.height + inset,
            width: max(120, normalizedRect.width * visible.width - spacing),
            height: max(90, normalizedRect.height * visible.height - spacing)
        )
        // AX 使用以主屏左上角为原点的全局坐标。
        let axRect = CGRect(
            x: cocoaRect.minX,
            y: screen.frame.maxY - cocoaRect.maxY,
            width: cocoaRect.width,
            height: cocoaRect.height
        )
        return setFrame(element, frame: axRect)
    }

    /// 静默摆位（只设位置大小，不置顶，用于批量摆放后统一置顶）
    @discardableResult
    func placeQuiet(_ window: WindowItem, normalizedRect: CGRect, spacing: CGFloat) -> Bool {
        guard hasAccessibilityPermission,
              let element = findWindow(window),
              let screen = NSScreen.main else { return false }

        let visible = screen.visibleFrame
        let inset = max(0, spacing / 2)
        let cocoaRect = CGRect(
            x: visible.minX + normalizedRect.minX * visible.width + inset,
            y: visible.minY + (1 - normalizedRect.maxY) * visible.height + inset,
            width: max(120, normalizedRect.width * visible.width - spacing),
            height: max(90, normalizedRect.height * visible.height - spacing)
        )
        let axRect = CGRect(
            x: cocoaRect.minX,
            y: screen.frame.maxY - cocoaRect.maxY,
            width: cocoaRect.width,
            height: cocoaRect.height
        )
        return setFrameQuiet(element, frame: axRect)
    }

    @discardableResult
    func restoreFrame(_ window: WindowItem, frame: CGRect) -> Bool {
        guard let element = findWindow(window) else { return false }
        return setFrame(element, frame: frame)
    }

    func hide(_ app: RunningAppItem) {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        running.hide()
        // 辅助型应用（LSUIElement / 菜单栏应用）的 hide() 经常无效，
        // 兜底对每个可见窗口做最小化，确保它们真正从桌面 / 调度中心消失。
        if running.activationPolicy == .accessory {
            minimizeAll(app)
        }
    }

    func show(_ app: RunningAppItem) {
        NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows])
        for window in app.windows {
            if let element = findWindow(window) {
                setBool(element, attribute: kAXMinimizedAttribute, value: false)
            }
        }
    }

    func minimizeAll(_ app: RunningAppItem) {
        guard hasAccessibilityPermission else { return }
        let appElement = AXUIElementCreateApplication(app.pid)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue) == .success,
              let elements = rawValue as? [AXUIElement] else { return }
        elements.forEach {
            setBool($0, attribute: kAXMinimizedAttribute, value: true)
        }
    }

    /// “回到桌面”专用兜底：有些 Electron / 自定义窗口应用会接受 hide 请求，
    /// 但窗口仍停留在当前桌面。只对复查后仍在屏幕上的应用执行 AX 最小化，
    /// 避免改变已经正常隐藏的应用窗口状态。
    func minimizeWindowsStillOnScreen(in apps: [RunningAppItem]) {
        let visiblePIDs = onScreenApplicationPIDs()
        for app in apps where visiblePIDs.contains(app.pid) {
            minimizeAll(app)
            closeKnownNonMinimizableFloatingWindows(in: app)
        }
    }

    func closeAll(_ app: RunningAppItem) {
        app.windows.forEach(close)
    }

    /// 发送正常退出请求（等价于 Command-Q），不阻塞界面，也不自动强制退出。
    @discardableResult
    func quit(_ app: RunningAppItem) -> QuitResult {
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.foldesk.mac"
        guard app.pid != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier != ownBundleID,
              app.bundleIdentifier != "com.foldesk.mac"
        else {
            return .failed
        }
        guard let running = NSRunningApplication(processIdentifier: app.pid) else {
            return .processNotFound
        }
        return running.terminate() ? .requested : .failed
    }

    func capturePreview(windowID: CGWindowID) async -> NSImage? {
        guard hasScreenRecordingPermission else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let targetWidth = min(max(Int(window.frame.width), 240), 520)
            let aspectRatio = window.frame.width > 0 ? window.frame.height / window.frame.width : 0.62
            configuration.width = targetWidth
            configuration.height = max(140, Int(Double(targetWidth) * aspectRatio))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: image, size: window.frame.size)
        } catch {
            return nil
        }
    }

    func restore(
        _ states: [SavedWindowState],
        applications: [RunningAppItem],
        preferences: AppPreferences,
        restoreMinimizedState: Bool = true
    ) {
        let grouped = Dictionary(grouping: states, by: \.bundleIdentifier)
        for app in applications {
            guard let states = grouped[app.bundleIdentifier] ?? grouped[nil]?.filter({ $0.appName == app.name }) else { continue }
            guard let running = NSRunningApplication(processIdentifier: app.pid) else { continue }
            running.unhide()
            running.activate(options: [])

            var usedWindowIDs: Set<String> = []
            for (index, state) in states.enumerated() {
                let exactMatch = app.windows.first {
                    $0.title == state.title && !usedWindowIDs.contains($0.id)
                }
                let positionalFallback: WindowItem? = {
                    guard states.count == app.windows.count,
                          app.windows.indices.contains(index),
                          !usedWindowIDs.contains(app.windows[index].id) else { return nil }
                    return app.windows[index]
                }()
                let singleWindowFallback = app.windows.count == 1 ? app.windows.first : nil
                guard let window = exactMatch ?? positionalFallback ?? singleWindowFallback,
                      let element = findWindow(window) else { continue }
                usedWindowIDs.insert(window.id)
                setBool(
                    element,
                    attribute: kAXMinimizedAttribute,
                    value: restoreMinimizedState ? state.wasMinimized : false
                )
                if preferences.rememberPosition {
                    var point = CGPoint(x: state.x, y: state.y)
                    if let value = AXValueCreate(.cgPoint, &point) {
                        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
                    }
                }
                if preferences.rememberSize {
                    var size = CGSize(width: state.width, height: state.height)
                    if let value = AXValueCreate(.cgSize, &size) {
                        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
                    }
                }
            }
        }
    }

    private func axWindows(pid: pid_t, appName: String, cgWindows: [WindowItem]) -> [WindowItem] {
        let appElement = AXUIElementCreateApplication(pid)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue) == .success,
              let elements = rawValue as? [AXUIElement] else { return [] }

        return elements.enumerated().compactMap { index, element in
            let title = stringValue(element, attribute: kAXTitleAttribute) ?? "未命名窗口"
            let minimized = boolValue(element, attribute: kAXMinimizedAttribute)
            let frame = frameValue(element)
            return WindowItem(
                id: "\(pid)-\(index)-\(title)",
                pid: pid,
                cgWindowID: cgWindows.first(where: { $0.title == title })?.cgWindowID
                    ?? (cgWindows.indices.contains(index) ? cgWindows[index].cgWindowID : nil),
                appName: appName,
                title: title.isEmpty ? "未命名窗口" : title,
                index: index,
                isMinimized: minimized,
                frame: frame
            )
        }
    }

    private func cgWindowFallback() -> [pid_t: [WindowItem]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [pid_t: [WindowItem]] = [:]
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let owner = info[kCGWindowOwnerName as String] as? String else { continue }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "窗口"
            let bounds = (info[kCGWindowBounds as String] as? [String: CGFloat]).flatMap {
                CGRect(x: $0["X"] ?? 0, y: $0["Y"] ?? 0, width: $0["Width"] ?? 0, height: $0["Height"] ?? 0)
            } ?? .zero
            let index = result[ownerPID]?.count ?? 0
            let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            result[ownerPID, default: []].append(
                WindowItem(id: "\(ownerPID)-cg-\(index)-\(title)", pid: ownerPID, cgWindowID: windowID, appName: owner, title: title, index: index, isMinimized: false, frame: bounds)
            )
        }
        return result
    }

    private func onScreenApplicationPIDs() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return Set(list.compactMap { info -> pid_t? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            // 自定义悬浮条可能位于普通窗口层之上（百度网盘为 layer 3），
            // 不能只检查 layer 0，否则主窗口收起后会漏掉这类残留浮窗。
            guard alpha > 0.01 else { return nil }

            guard let rawBounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                return ownerPID
            }
            let width = rawBounds["Width"] ?? 0
            let height = rawBounds["Height"] ?? 0
            return width >= 40 && height >= 40 ? ownerPID : nil
        })
    }

    /// 百度网盘的悬浮条是一个不支持 AXMinimized、没有 AXCloseButton 的自定义窗口，
    /// 即使应用已隐藏也会继续停在桌面。只对这个已知 bundle ID 的紧凑悬浮窗口
    /// 定向发送 Command-W；主窗口仍然只是最小化，不会退出应用或丢失会话。
    private func closeKnownNonMinimizableFloatingWindows(in app: RunningAppItem) {
        guard app.bundleIdentifier == "com.baidu.BaiduNetdisk-mac" else { return }

        let appElement = AXUIElementCreateApplication(app.pid)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue) == .success,
              let elements = rawValue as? [AXUIElement] else { return }

        for element in elements {
            let frame = frameValue(element)
            guard !boolValue(element, attribute: kAXMinimizedAttribute),
                  frame.width > 0, frame.height > 0,
                  frame.width <= 360, frame.height <= 160 else { continue }

            setBool(element, attribute: kAXFocusedAttribute, value: true)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: false) else {
                continue
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.postToPid(app.pid)
            keyUp.postToPid(app.pid)
        }

        NSRunningApplication(processIdentifier: app.pid)?.hide()
    }

    private func findWindow(_ window: WindowItem) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(window.pid)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue) == .success,
              let elements = rawValue as? [AXUIElement] else { return nil }

        let normalizedTargetTitle = normalizedWindowTitle(window.title)

        // WindowItem 是同一次 AX 扫描按 index 生成的。优先使用 index，
        // 可以稳定区分多个同叫“未命名窗口”的 NSPanel。
        if elements.indices.contains(window.index) {
            let indexed = elements[window.index]
            if normalizedWindowTitle(stringValue(indexed, attribute: kAXTitleAttribute)) == normalizedTargetTitle {
                return indexed
            }
        }

        let titleMatches = elements.filter {
            normalizedWindowTitle(stringValue($0, attribute: kAXTitleAttribute)) == normalizedTargetTitle
        }
        if titleMatches.count == 1 { return titleMatches[0] }

        // 窗口顺序在扫描后变化时，对同名窗口用扫描时 frame 做最近邻匹配。
        if !titleMatches.isEmpty {
            return titleMatches.min { lhs, rhs in
                frameDistance(frameValue(lhs), window.frame) < frameDistance(frameValue(rhs), window.frame)
            }
        }
        return elements.indices.contains(window.index) ? elements[window.index] : nil
    }

    private func normalizedWindowTitle(_ title: String?) -> String {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value == "未命名窗口" || value == "窗口" ? "未命名窗口" : value
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width) * 2
            + abs(lhs.height - rhs.height) * 2
    }

    private func stringValue(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolValue(_ element: AXUIElement, attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func frameValue(_ element: AXUIElement) -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var point = CGPoint.zero
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
           let value = positionValue {
            AXValueGetValue(value as! AXValue, .cgPoint, &point)
        }
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let value = sizeValue {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: point, size: size)
    }

    private func setBool(_ element: AXUIElement, attribute: String, value: Bool) {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean)
    }

    /// 设置窗口位置和大小（含取消最小化 + 置顶）
    private func setFrame(_ element: AXUIElement, frame: CGRect) -> Bool {
        setBool(element, attribute: kAXMinimizedAttribute, value: false)
        var size = frame.size
        var point = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let pointValue = AXValueCreate(.cgPoint, &point) else { return false }
        let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let pointResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pointValue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard sizeResult == .success, pointResult == .success else { return false }
        return frameValue(element).isApproximatelyEqual(to: frame)
    }

    /// 静默设置窗口位置和大小（不含置顶，避免分屏时逐个闪烁）
    func setFrameQuiet(_ element: AXUIElement, frame: CGRect) -> Bool {
        setBool(element, attribute: kAXMinimizedAttribute, value: false)
        var size = frame.size
        var point = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let pointValue = AXValueCreate(.cgPoint, &point) else { return false }
        let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let pointResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pointValue)
        // 注意：这里不调 AXRaiseAction，避免每个窗口摆放时闪烁。
        // AX 返回 success 只表示请求被接收；应用可以因最小尺寸或 NSPanel 策略拒绝它。
        // 必须回读实际 frame，否则会虚假报告“已排列”。
        guard sizeResult == .success, pointResult == .success else { return false }
        return frameValue(element).isApproximatelyEqual(to: frame)
    }

    private func openPrivacySettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension CGRect {
    func isApproximatelyEqual(to other: CGRect, positionTolerance: CGFloat = 3, sizeTolerance: CGFloat = 6) -> Bool {
        abs(minX - other.minX) <= positionTolerance
            && abs(minY - other.minY) <= positionTolerance
            && abs(width - other.width) <= sizeTolerance
            && abs(height - other.height) <= sizeTolerance
    }
}

/// 退出操作的结果
enum QuitResult: Equatable {
    case requested            // 已发送正常退出请求
    case processNotFound      // 进程已不存在
    case failed               // 应用拒绝了退出请求

    var description: String {
        switch self {
        case .requested: "已发送正常退出请求"
        case .processNotFound: "进程已不存在"
        case .failed: "应用拒绝了退出请求"
        }
    }
}
