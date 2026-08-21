import AppKit
import SwiftUI

@main
struct FoldeskApp: App {
    @NSApplicationDelegateAdaptor(FoldeskAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Foldesk", id: "main") {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(state.preferences.appearance.colorScheme)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Foldesk") {
                Button("收起全部") { state.foldAll() }
                    .keyboardShortcut("d", modifiers: [.option])
                Button("恢复刚才") { state.restoreLatest() }
                    .keyboardShortcut("r", modifiers: [.option])
                Divider()
                Button("刷新窗口") { state.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }

        // isInserted 绑定到 keepMenuBar，让「菜单栏常驻」这个偏好真正生效。
        // 此前该字段只被声明与持久化，从未被任何视图读取（死代码）。
        MenuBarExtra(
            "Foldesk",
            systemImage: "rectangle.3.group.fill",
            isInserted: $state.preferences.keepMenuBar
        ) {
            MenuPanel()
                .environmentObject(state)
                .preferredColorScheme(state.preferences.appearance.colorScheme)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPage()
                .environmentObject(state)
                .preferredColorScheme(state.preferences.appearance.colorScheme)
                .frame(width: 650, height: 600)
        }
    }
}

struct MenuPanel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(nsImage: .foldeskBrandIcon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Foldesk").font(.headline)
                    Text("\(state.applications.count) 个应用 · \(state.windowCount) 个窗口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { state.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            Divider()
            ActionButton(title: "收起全部", symbol: "arrow.down.to.line", prominent: true) {
                state.foldAll()
            }
            ActionButton(title: "恢复刚才", symbol: "arrow.uturn.backward") {
                state.restoreLatest()
            }
            Button {
                openWindow(id: "main")
                DispatchQueue.main.async {
                    state.summonApp()
                }
            } label: {
                Label("打开 Foldesk", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Divider()
            HStack {
                Button("设置…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                    .buttonStyle(.plain)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
    }
}
