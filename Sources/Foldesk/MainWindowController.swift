import AppKit
import FoldeskShared
import SwiftUI

// NSServices 的 error: 参数是 NSString **，不是 NSError **。
typealias ServiceErrorPointer = AutoreleasingUnsafeMutablePointer<NSString?>?

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    private let mainWindowIdentifier = NSUserInterfaceItemIdentifier("Foldesk.MainWindow")
    private var fallbackWindow: NSWindow?

    func show(state: AppState) {
        NSApp.activate(ignoringOtherApps: true)

        if let window = existingMainWindow {
            WindowFrameGuard.constrain(window)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = mainWindowIdentifier
        window.title = "Foldesk"
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: RootView()
                .environmentObject(state)
                .preferredColorScheme(state.preferences.appearance.colorScheme)
        )
        window.setFrameAutosaveName("Foldesk.MainWindow.Frame")
        if !window.setFrameUsingName("Foldesk.MainWindow.Frame") {
            window.center()
        }
        WindowFrameGuard.constrain(window)
        fallbackWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func minimize() {
        existingMainWindow?.miniaturize(nil)
    }

    private var existingMainWindow: NSWindow? {
        if let fallbackWindow, fallbackWindow.isVisible || fallbackWindow.isMiniaturized {
            return fallbackWindow
        }
        return NSApp.windows.first { window in
            guard !(window is NSPanel),
                  window.canBecomeMain,
                  window.isVisible || window.isMiniaturized
            else { return false }
            return window.identifier == mainWindowIdentifier || window.title == "Foldesk"
        }
    }
}

@MainActor
final class FoldeskAppDelegate: NSObject, NSApplicationDelegate {
    private var launchedForBackgroundRequest = false
    private var activeServiceOperations = 0
    private var didPresentInitialFloatingUI = false

    static func isDefaultLaunch(_ notification: Notification) -> Bool {
        (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber)?.boolValue ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 注册为系统服务的提供方，使 Info.plist 中声明的 NSServices 能路由到本类方法。
        launchedForBackgroundRequest = !Self.isDefaultLaunch(notification)
        NSLog("Foldesk: 启动模式 = %@", launchedForBackgroundRequest ? "右键服务" : "交互界面")
        NSApp.setActivationPolicy(.regular)
        // 注册后服务可能立刻到达，必须先设好启动模式。
        NSApp.servicesProvider = self

        // macOS 为执行 NSServices 冷启动 App 时，default launch 会是 false。
        // 该场景只注册服务，不初始化窗口工作台，也不弹主窗口。
        if !launchedForBackgroundRequest {
            presentInteractiveUI()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentInteractiveUI()
        return true
    }

    private func presentInteractiveUI() {
        launchedForBackgroundRequest = false
        NSApp.setActivationPolicy(.regular)
        AppState.shared.prepareForInteractiveUse()
        DispatchQueue.main.async {
            MainWindowController.shared.show(state: .shared)
            guard !self.didPresentInitialFloatingUI else { return }
            self.didPresentInitialFloatingUI = true
            if AppState.shared.preferences.showFloatingConsole {
                if !AppState.shared.activeWorkspaceIDs.isEmpty {
                    AppState.shared.showAllFloatingWorkspacePanels()
                } else {
                    AppState.shared.showFloatingConsole()
                }
            }
        }
    }

    private func beginServiceOperation() {
        activeServiceOperations += 1
        if launchedForBackgroundRequest {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func finishServiceOperation() {
        activeServiceOperations = max(0, activeServiceOperations - 1)
        guard launchedForBackgroundRequest, activeServiceOperations == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard self.launchedForBackgroundRequest, self.activeServiceOperations == 0 else { return }
            NSApp.terminate(nil)
        }
    }

    private func setServiceError(_ pointer: ServiceErrorPointer, _ message: String) {
        pointer?.pointee = message as NSString
    }

    private func presentServiceError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func completeBackgroundService(
        reveal urls: [URL] = [],
        errorTitle: String? = nil,
        errorMessage: String? = nil
    ) {
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        if let errorTitle, let errorMessage {
            presentServiceError(title: errorTitle, message: errorMessage)
        }
        finishServiceOperation()
    }

    // MARK: - 右键「服务」(NSServices) 处理

    /// 新建文件（无选中项时落在当前访达目录）。所有类型只创建，不打开关联 App。
    @objc func foldNewExcel(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        createFileFromFinder(.xlsx)
    }

    @objc func foldNewWord(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        createFileFromFinder(.docx)
    }

    @objc func foldNewPPT(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        createFileFromFinder(.pptx)
    }

    @objc func foldNewText(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        createFileFromFinder(.txt)
    }

    @objc func foldNewMarkdown(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        createFileFromFinder(.markdown)
    }

    @objc func foldNewRTF(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        createFileFromFinder(.rtf)
    }

    @objc func foldNewCSV(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        createFileFromFinder(.csv)
    }

    @objc func foldNewJSON(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        createFileFromFinder(.json)
    }

    @objc func foldNewHTML(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        createFileFromFinder(.html)
    }

    @objc func foldNewXML(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        createFileFromFinder(.xml)
    }

    @objc func foldNewEmpty(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        createFileFromFinder(.empty)
    }

    /// 复制路径 / 文件名（需选中文件）。
    @objc func foldCopyPath(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        beginServiceOperation()
        if !FoldeskServices.copyPaths(FoldeskServices.fileURLs(from: pboard)) {
            setServiceError(error, FoldeskServiceError.noSelection.localizedDescription)
        }
        finishServiceOperation()
    }

    @objc func foldCopyName(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        beginServiceOperation()
        if !FoldeskServices.copyNames(FoldeskServices.fileURLs(from: pboard)) {
            setServiceError(error, FoldeskServiceError.noSelection.localizedDescription)
        }
        finishServiceOperation()
    }

    /// 压缩为 zip / 解压到此处。
    @objc func foldCompress(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        let urls = FoldeskServices.fileURLs(from: pboard)
        beginServiceOperation()
        guard !urls.isEmpty else {
            setServiceError(error, FoldeskServiceError.noSelection.localizedDescription)
            finishServiceOperation()
            return
        }
        Task.detached(priority: .userInitiated) {
            let archive = FoldeskServices.compress(urls)
            await MainActor.run {
                if let archive {
                    self.completeBackgroundService(reveal: [archive])
                } else {
                    self.completeBackgroundService(
                        errorTitle: "压缩失败",
                        errorMessage: "无法创建 zip 文件，请检查文件权限和可用空间。"
                    )
                }
            }
        }
    }

    @objc func foldExtract(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        let urls = FoldeskServices.fileURLs(from: pboard)
        beginServiceOperation()
        guard !urls.isEmpty else {
            setServiceError(error, FoldeskServiceError.noSelection.localizedDescription)
            finishServiceOperation()
            return
        }
        Task.detached(priority: .userInitiated) {
            let result = FoldeskServices.extractResult(urls)
            await MainActor.run {
                self.completeBackgroundService(
                    reveal: result.destinations,
                    errorTitle: result.errorMessage == nil ? nil : "解压未完全成功",
                    errorMessage: result.errorMessage
                )
            }
        }
    }

    /// 彻底删除（弹窗二次确认）。
    @objc func foldDelete(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        let urls = FoldeskServices.fileURLs(from: pboard)
        beginServiceOperation()
        guard !urls.isEmpty else {
            setServiceError(error, FoldeskServiceError.noSelection.localizedDescription)
            finishServiceOperation()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let result = FoldeskServices.permanentDelete(urls)
        if !result.failedItems.isEmpty {
            presentServiceError(
                title: "未能彻底删除",
                message: result.deletedItems.isEmpty
                    ? "所选项目受系统保护，或当前没有删除权限。"
                    : "已删除 \(result.deletedItems.count) 项，失败 \(result.failedItems.count) 项。"
            )
        }
        finishServiceOperation()
    }

    /// 复制到常用目录 1 / 2 / 3（槽位名对应 FinderMenuPage 中配置的前 3 个目录）。
    @objc func foldCopyToDir1(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        transferFiles(from: pboard, toDirIndex: 0, move: false, error: error)
    }

    @objc func foldCopyToDir2(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        transferFiles(from: pboard, toDirIndex: 1, move: false, error: error)
    }

    @objc func foldCopyToDir3(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        transferFiles(from: pboard, toDirIndex: 2, move: false, error: error)
    }

    /// 移动到常用目录 1 / 2 / 3。
    @objc func foldMoveToDir1(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        transferFiles(from: pboard, toDirIndex: 0, move: true, error: error)
    }

    @objc func foldMoveToDir2(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        transferFiles(from: pboard, toDirIndex: 1, move: true, error: error)
    }

    @objc func foldMoveToDir3(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        transferFiles(from: pboard, toDirIndex: 2, move: true, error: error)
    }

    /// 用指定 App 打开 1 / 2 / 3（槽位名对应 FinderMenuPage 中配置的前 3 个 App）。
    @objc func foldOpenWith1(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        openFiles(from: pboard, appIndex: 0, error: error)
    }

    @objc func foldOpenWith2(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        openFiles(from: pboard, appIndex: 1, error: error)
    }

    @objc func foldOpenWith3(_ pboard: NSPasteboard, userData: String?, error: ServiceErrorPointer) {
        openFiles(from: pboard, appIndex: 2, error: error)
    }

    private func createFileFromFinder(_ kind: FoldeskNewFileKind) {
        beginServiceOperation()
        Task.detached(priority: .userInitiated) {
            do {
                let folder = try FoldeskServices.currentFinderFolder()
                let created = FoldeskServices.createFile(kind: kind, in: folder)
                await MainActor.run {
                    if let created {
                        // “新建”只负责在当前目录落盘。不要调用
                        // activateFileViewerSelecting：当前文件夹会自行刷新，且不应
                        // 把焦点交给 WPS 等文件关联应用。
                        NSLog("Foldesk: 已在当前访达目录新建文件：%@", created.lastPathComponent)
                        self.finishServiceOperation()
                    } else {
                        self.completeBackgroundService(
                            errorTitle: "新建文件失败",
                            errorMessage: "无法在当前访达目录创建文件，请检查写入权限。"
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.completeBackgroundService(
                        errorTitle: "无法读取访达目录",
                        errorMessage: error.localizedDescription
                    )
                }
            }
        }
    }

    private func transferFiles(
        from pboard: NSPasteboard,
        toDirIndex index: Int,
        move: Bool,
        error: ServiceErrorPointer
    ) {
        let urls = FoldeskServices.fileURLs(from: pboard)
        beginServiceOperation()
        guard !urls.isEmpty else {
            setServiceError(error, FoldeskServiceError.noSelection.localizedDescription)
            finishServiceOperation()
            return
        }
        Task.detached(priority: .userInitiated) {
            let result = FoldeskServices.copyOrMove(urls, toDirIndex: index, move: move)
            await MainActor.run {
                self.completeBackgroundService(
                    reveal: result.destinations,
                    errorTitle: result.errorMessage == nil ? nil : (move ? "移动未完全成功" : "复制未完全成功"),
                    errorMessage: result.errorMessage
                )
            }
        }
    }

    private func openFiles(from pboard: NSPasteboard, appIndex index: Int, error: ServiceErrorPointer) {
        let urls = FoldeskServices.fileURLs(from: pboard)
        beginServiceOperation()
        guard !urls.isEmpty else {
            setServiceError(error, FoldeskServiceError.noSelection.localizedDescription)
            finishServiceOperation()
            return
        }
        FoldeskServices.openWith(urls, appIndex: index) { openError in
            if let openError {
                self.presentServiceError(title: "无法用指定 App 打开", message: openError.localizedDescription)
            }
            self.finishServiceOperation()
        }
    }
}
