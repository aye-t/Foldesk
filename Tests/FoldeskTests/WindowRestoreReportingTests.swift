import CoreGraphics
import AppKit
@testable import Foldesk
import XCTest

/// 回归测试：`restore` 必须返回**真实**还原数量。
///
/// 修复前 `restore` 返回 Void，调用方直接用 `record.windows.count` 生成
/// “正在恢复 N 个窗口” 的提示——即使一个窗口都没还原（应用已退出、
/// 或没有辅助功能权限）也照样报成功，是典型的假成功。
@MainActor
final class WindowRestoreReportingTests: XCTestCase {
    func testRestoreReportsZeroWhenNoTargetApplicationIsRunning() {
        let manager = WindowManager()
        let states = [
            savedState(appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            savedState(appName: "备忘录", bundleIdentifier: "com.apple.Notes")
        ]

        // 目标应用全部不在运行列表中，任何窗口都不可能被还原。
        let restored = manager.restore(
            states,
            applications: [],
            preferences: AppPreferences()
        )

        XCTAssertEqual(
            restored,
            0,
            "没有任何目标应用在运行时，restore 必须返回 0，不能让调用方误报成功"
        )
    }

    func testRestoreReportsZeroWhenRunningApplicationHasNoWindows() {
        let manager = WindowManager()
        let states = [savedState(appName: "Safari", bundleIdentifier: "com.apple.Safari")]

        // 进程存在但没有任何窗口可匹配，同样应返回 0。
        let app = RunningAppItem(
            id: "com.apple.Safari",
            pid: -1,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: nil,
            icon: NSImage(),
            windows: [],
            isActive: false
        )

        let restored = manager.restore(
            states,
            applications: [app],
            preferences: AppPreferences()
        )

        XCTAssertEqual(restored, 0)
    }

    private func savedState(
        appName: String,
        bundleIdentifier: String?
    ) -> SavedWindowState {
        SavedWindowState(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            title: "\(appName) 窗口",
            x: 100,
            y: 100,
            width: 800,
            height: 600,
            wasMinimized: false
        )
    }
}
