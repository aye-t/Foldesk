import AppKit
import Foundation
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case applications = "窗口总览"
    case recent = "最近收起"
    case workspaces = "我的工作区"
    case splitLayout = "分屏布局"
    case batch = "批量操作"
    case finderMenu = "右键菜单"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .applications: "square.grid.2x2"
        case .recent: "clock"
        case .workspaces: "rectangle.3.group"
        case .splitLayout: "rectangle.split.3x1"
        case .batch: "square.stack.3d.up"
        case .finderMenu: "menubar.rectangle"
        case .settings: "gearshape"
        }
    }
}

struct WindowItem: Identifiable, Hashable {
    let id: String
    let pid: pid_t
    let cgWindowID: CGWindowID?
    let appName: String
    let title: String
    let index: Int
    let isMinimized: Bool
    let frame: CGRect
}

enum WorkspaceWindowSelection {
    /// AXWindows 的顺序会随着悬浮面板显隐变化。选择工作区的主窗口时，
    /// 必须依据窗口语义和尺寸，而不是数组下标。
    static func preferredPrimaryWindow(
        in windows: [WindowItem],
        appName: String
    ) -> WindowItem? {
        windows.max { lhs, rhs in
            primaryWindowScore(lhs, appName: appName) < primaryWindowScore(rhs, appName: appName)
        }
    }

    private static func primaryWindowScore(_ window: WindowItem, appName: String) -> Double {
        let normalizedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUntitled = normalizedTitle.isEmpty || normalizedTitle == "未命名窗口" || normalizedTitle == "窗口"
        let titleMatchesApp = normalizedTitle.localizedCaseInsensitiveContains(appName)
            || appName.localizedCaseInsensitiveContains(normalizedTitle)
        let area = max(0, Double(window.frame.width * window.frame.height))

        var score = min(area / 1_000, 2_000)
        if !isUntitled { score += 4_000 }
        if titleMatchesApp && !isUntitled { score += 8_000 }
        if window.frame.width >= 480 && window.frame.height >= 320 { score += 2_000 }
        if window.isMinimized { score -= 500 }
        if isUntitled && (window.frame.width < 360 || window.frame.height < 220) { score -= 6_000 }
        return score
    }
}

struct RunningAppItem: Identifiable {
    let id: String
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    var windows: [WindowItem]
    let isActive: Bool

    var icon: NSImage {
        guard let bundleURL else { return NSImage(systemSymbolName: "app", accessibilityDescription: nil)! }
        return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }
}

struct SavedWindowState: Codable, Hashable {
    let appName: String
    let bundleIdentifier: String?
    let title: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let wasMinimized: Bool
}

struct FoldRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let date: Date
    let windows: [SavedWindowState]
    var restored: Bool

    var applicationCount: Int { Set(windows.map(\.appName)).count }
}

struct WorkspaceApplication: Codable, Identifiable, Hashable {
    let name: String
    let bundleIdentifier: String?
    let bundlePath: String?

    var id: String { bundleIdentifier ?? bundlePath ?? name }
}

enum WorkspaceLayoutKind: String, CaseIterable, Codable, Identifiable {
    case halves = "左右分屏"
    case stacked = "上下分屏"
    case focus = "左一右二"
    case grid = "四宫格"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .halves: "rectangle.split.2x1"
        case .stacked: "rectangle.split.1x2"
        case .focus: "rectangle.split.1x2"
        case .grid: "square.grid.2x2"
        }
    }

    var regions: [CGRect] {
        switch self {
        case .halves:
            [
                CGRect(x: 0, y: 0, width: 0.5, height: 1),
                CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
            ]
        case .stacked:
            [
                CGRect(x: 0, y: 0, width: 1, height: 0.5),
                CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
            ]
        case .focus:
            [
                CGRect(x: 0, y: 0, width: 0.6, height: 1),
                CGRect(x: 0.6, y: 0, width: 0.4, height: 0.5),
                CGRect(x: 0.6, y: 0.5, width: 0.4, height: 0.5)
            ]
        case .grid:
            [
                CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
            ]
        }
    }
}

struct WorkspaceItem: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var symbol: String
    var colorName: String
    let createdAt: Date
    var windows: [SavedWindowState]
    var applications: [WorkspaceApplication]? = nil
    var autoLaunchApplicationIDs: Set<String>? = nil
    var layoutKind: WorkspaceLayoutKind? = nil
    var slotAssignments: [String: Int]? = nil

    var applicationCount: Int { applicationNames.count }

    var applicationNames: [String] {
        if let applications, !applications.isEmpty {
            return applications.map(\.name)
        }
        return Array(Set(windows.map(\.appName))).sorted()
    }

    var memberApplications: [WorkspaceApplication] {
        if let applications, !applications.isEmpty {
            return applications
        }
        var seen: Set<String> = []
        return windows.compactMap { window in
            let id = window.bundleIdentifier ?? window.appName
            guard seen.insert(id).inserted else { return nil }
            return WorkspaceApplication(
                name: window.appName,
                bundleIdentifier: window.bundleIdentifier,
                bundlePath: nil
            )
        }
    }

    var autoLaunchIDs: Set<String> {
        autoLaunchApplicationIDs ?? []
    }

    var assignedLayout: WorkspaceLayoutKind {
        layoutKind ?? .focus
    }

    func slot(for member: WorkspaceApplication) -> Int? {
        slotAssignments?[member.id]
    }
}

enum FoldMode: String, CaseIterable, Codable, Identifiable {
    case hide = "隐藏应用"
    case minimize = "缩小窗口"
    case mixed = "混合模式"
    var id: String { rawValue }
}

enum AppAppearance: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "白天"
        case .dark: "黑夜"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct AppPreferences: Codable {
    var foldMode: FoldMode = .hide
    var appearance: AppAppearance = .system
    var showRecoveryOverlay = true
    var rememberPosition = true
    var rememberSize = true
    var confirmRiskyActions = true
    var saveHistory = true
    var keepMenuBar = true
    var showFloatingConsole = true
    var excludedBundleIDs: Set<String> = []
    // 全局唤起快捷键：-1 表示未设置；summonModifiers 为 NSEvent.ModifierFlags 的 rawValue
    var summonKeyCode: Int = -1
    var summonModifiers: UInt = 0
    var summonKeyLabel: String = ""

    private enum CodingKeys: String, CodingKey {
        case foldMode
        case appearance
        case showRecoveryOverlay
        case rememberPosition
        case rememberSize
        case confirmRiskyActions
        case saveHistory
        case keepMenuBar
        case showFloatingConsole
        case excludedBundleIDs
        case summonKeyCode
        case summonModifiers
        case summonKeyLabel
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        foldMode = try values.decodeIfPresent(FoldMode.self, forKey: .foldMode) ?? .hide
        appearance = try values.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        showRecoveryOverlay = try values.decodeIfPresent(Bool.self, forKey: .showRecoveryOverlay) ?? true
        rememberPosition = try values.decodeIfPresent(Bool.self, forKey: .rememberPosition) ?? true
        rememberSize = try values.decodeIfPresent(Bool.self, forKey: .rememberSize) ?? true
        confirmRiskyActions = try values.decodeIfPresent(Bool.self, forKey: .confirmRiskyActions) ?? true
        saveHistory = try values.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? true
        keepMenuBar = try values.decodeIfPresent(Bool.self, forKey: .keepMenuBar) ?? true
        showFloatingConsole = try values.decodeIfPresent(Bool.self, forKey: .showFloatingConsole) ?? true
        excludedBundleIDs = try values.decodeIfPresent(Set<String>.self, forKey: .excludedBundleIDs) ?? []
        summonKeyCode = try values.decodeIfPresent(Int.self, forKey: .summonKeyCode) ?? -1
        summonModifiers = try values.decodeIfPresent(UInt.self, forKey: .summonModifiers) ?? 0
        summonKeyLabel = try values.decodeIfPresent(String.self, forKey: .summonKeyLabel) ?? ""
    }
}
