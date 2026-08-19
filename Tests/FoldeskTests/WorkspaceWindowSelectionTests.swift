import CoreGraphics
@testable import Foldesk
import XCTest

final class WorkspaceWindowSelectionTests: XCTestCase {
    func testPrefersFoldeskMainWindowOverEarlierUntitledPanels() throws {
        let windows = [
            window(index: 0, title: "未命名窗口", width: 248, height: 295),
            window(index: 1, title: "未命名窗口", width: 300, height: 88),
            window(index: 2, title: "Foldesk", width: 1_120, height: 795)
        ]

        let selected = try XCTUnwrap(
            WorkspaceWindowSelection.preferredPrimaryWindow(in: windows, appName: "Foldesk")
        )

        XCTAssertEqual(selected.index, 2)
        XCTAssertEqual(selected.title, "Foldesk")
    }

    func testSelectionDoesNotDependOnAXWindowOrder() throws {
        let main = window(index: 0, title: "Foldesk", width: 1_120, height: 795)
        let panel = window(index: 1, title: "未命名窗口", width: 288, height: 477)

        for candidates in [[main, panel], [panel, main]] {
            let selected = try XCTUnwrap(
                WorkspaceWindowSelection.preferredPrimaryWindow(in: candidates, appName: "Foldesk")
            )
            XCTAssertEqual(selected.title, "Foldesk")
        }
    }

    func testLargeNamedWindowBeatsSmallNamedUtilityWindow() throws {
        let selected = try XCTUnwrap(
            WorkspaceWindowSelection.preferredPrimaryWindow(
                in: [
                    window(index: 0, title: "Foldesk 设置", width: 420, height: 260),
                    window(index: 1, title: "Foldesk", width: 1_180, height: 760)
                ],
                appName: "Foldesk"
            )
        )

        XCTAssertEqual(selected.index, 1)
    }

    private func window(index: Int, title: String, width: CGFloat, height: CGFloat) -> WindowItem {
        WindowItem(
            id: "window-\(index)",
            pid: 123,
            cgWindowID: nil,
            appName: "Foldesk",
            title: title,
            index: index,
            isMinimized: false,
            frame: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }
}
