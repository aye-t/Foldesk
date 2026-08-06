import CoreGraphics
@testable import Foldesk
import XCTest

final class WorkspaceWindowSelectionTests: XCTestCase {
    func testPrefersFocusDockMainWindowOverEarlierUntitledPanels() throws {
        let windows = [
            window(index: 0, title: "未命名窗口", width: 248, height: 295),
            window(index: 1, title: "未命名窗口", width: 300, height: 88),
            window(index: 2, title: "FocusDock", width: 1_120, height: 795)
        ]

        let selected = try XCTUnwrap(
            WorkspaceWindowSelection.preferredPrimaryWindow(in: windows, appName: "FocusDock")
        )

        XCTAssertEqual(selected.index, 2)
        XCTAssertEqual(selected.title, "FocusDock")
    }

    func testSelectionDoesNotDependOnAXWindowOrder() throws {
        let main = window(index: 0, title: "FocusDock", width: 1_120, height: 795)
        let panel = window(index: 1, title: "未命名窗口", width: 288, height: 477)

        for candidates in [[main, panel], [panel, main]] {
            let selected = try XCTUnwrap(
                WorkspaceWindowSelection.preferredPrimaryWindow(in: candidates, appName: "FocusDock")
            )
            XCTAssertEqual(selected.title, "FocusDock")
        }
    }

    @MainActor
    func testLiveFocusDockSelectsNamedMainWindowWhenAvailable() throws {
        let manager = WindowManager()
        guard let app = manager.scanApplications().first(where: {
            $0.bundleIdentifier == "com.focusdock.mac"
        }) else {
            throw XCTSkip("FocusDock is not running")
        }

        let selected = try XCTUnwrap(
            WorkspaceWindowSelection.preferredPrimaryWindow(in: app.windows, appName: app.name)
        )

        XCTAssertEqual(selected.title, "FocusDock")
        XCTAssertGreaterThan(selected.frame.width, 480)
        XCTAssertGreaterThan(selected.frame.height, 320)
    }

    private func window(index: Int, title: String, width: CGFloat, height: CGFloat) -> WindowItem {
        WindowItem(
            id: "window-\(index)",
            pid: 123,
            cgWindowID: nil,
            appName: "FocusDock",
            title: title,
            index: index,
            isMinimized: false,
            frame: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }
}
