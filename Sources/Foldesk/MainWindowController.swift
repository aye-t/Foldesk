import AppKit
import SwiftUI

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 注册为系统服务的提供方，使 Info.plist 中声明的 NSServices 能路由到本类方法。
        NSApp.servicesProvider = self
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            MainWindowController.shared.show(state: .shared)
            if AppState.shared.preferences.showFloatingConsole {
                if !AppState.shared.activeWorkspaceIDs.isEmpty {
                    AppState.shared.showAllFloatingWorkspacePanels()
                } else {
                    AppState.shared.showFloatingConsole()
                }
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        MainWindowController.shared.show(state: .shared)
        return true
    }

    // MARK: - 右键「服务」(NSServices) 处理

    /// 新建 Excel / Word / PPT / 文本 / Markdown（无选中项时落在当前访达目录）。
    @objc func foldNewExcel(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        createFileFromFinder(template: "Empty", ext: "xlsx")
    }

    @objc func foldNewWord(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        createFileFromFinder(template: "Empty", ext: "docx")
    }

    @objc func foldNewPPT(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        createFileFromFinder(template: "Empty", ext: "pptx")
    }

    @objc func foldNewText(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        createFileFromFinder(template: nil, ext: "txt")
    }

    @objc func foldNewMarkdown(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        createFileFromFinder(template: nil, ext: "md")
    }

    /// 复制路径 / 文件名（需选中文件）。
    @objc func foldCopyPath(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        FoldeskServices.copyPaths(FoldeskServices.fileURLs(from: pboard))
    }

    @objc func foldCopyName(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        FoldeskServices.copyNames(FoldeskServices.fileURLs(from: pboard))
    }

    /// 压缩为 zip / 解压到此处。
    @objc func foldCompress(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        let urls = FoldeskServices.fileURLs(from: pboard)
        Task.detached(priority: .userInitiated) {
            _ = FoldeskServices.compress(urls)
        }
    }

    @objc func foldExtract(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        let urls = FoldeskServices.fileURLs(from: pboard)
        Task.detached(priority: .userInitiated) {
            _ = FoldeskServices.extract(urls)
        }
    }

    /// 彻底删除（弹窗二次确认）。
    @objc func foldDelete(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        FoldeskServices.permanentDelete(FoldeskServices.fileURLs(from: pboard))
    }

    /// 复制到常用目录 1 / 2 / 3（槽位名对应 FinderMenuPage 中配置的前 3 个目录）。
    @objc func foldCopyToDir1(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        _ = FoldeskServices.copyOrMove(FoldeskServices.fileURLs(from: pboard), toDirIndex: 0, move: false)
    }

    @objc func foldCopyToDir2(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        _ = FoldeskServices.copyOrMove(FoldeskServices.fileURLs(from: pboard), toDirIndex: 1, move: false)
    }

    @objc func foldCopyToDir3(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        _ = FoldeskServices.copyOrMove(FoldeskServices.fileURLs(from: pboard), toDirIndex: 2, move: false)
    }

    /// 移动到常用目录 1 / 2 / 3。
    @objc func foldMoveToDir1(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        _ = FoldeskServices.copyOrMove(FoldeskServices.fileURLs(from: pboard), toDirIndex: 0, move: true)
    }

    @objc func foldMoveToDir2(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        _ = FoldeskServices.copyOrMove(FoldeskServices.fileURLs(from: pboard), toDirIndex: 1, move: true)
    }

    @objc func foldMoveToDir3(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        _ = FoldeskServices.copyOrMove(FoldeskServices.fileURLs(from: pboard), toDirIndex: 2, move: true)
    }

    /// 用指定 App 打开 1 / 2 / 3（槽位名对应 FinderMenuPage 中配置的前 3 个 App）。
    @objc func foldOpenWith1(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        FoldeskServices.openWith(FoldeskServices.fileURLs(from: pboard), appIndex: 0)
    }

    @objc func foldOpenWith2(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        FoldeskServices.openWith(FoldeskServices.fileURLs(from: pboard), appIndex: 1)
    }

    @objc func foldOpenWith3(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        FoldeskServices.openWith(FoldeskServices.fileURLs(from: pboard), appIndex: 2)
    }

    private func createFileFromFinder(template: String?, ext: String) {
        Task.detached(priority: .userInitiated) {
            let folder = FoldeskServices.currentFinderFolder()
            _ = FoldeskServices.createFile(
                template: template,
                ext: ext,
                defaultBase: "未命名",
                in: folder
            )
        }
    }
}
