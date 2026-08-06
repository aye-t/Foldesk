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

final class FoldeskAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
