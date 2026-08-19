import AppKit
@testable import Foldesk
import XCTest

final class FloatingPanelGeometryTests: XCTestCase {
    func testOversizedPanelIsFittedInsideVisibleScreen() {
        let visible = NSRect(x: 100, y: 50, width: 320, height: 240)
        let frame = NSRect(x: -400, y: -300, width: 600, height: 700)

        let result = FloatingPanelGeometry.constrained(frame, to: visible)

        XCTAssertEqual(result.width, 304)
        XCTAssertEqual(result.height, 224)
        XCTAssertGreaterThanOrEqual(result.minX, visible.minX + 8)
        XCTAssertGreaterThanOrEqual(result.minY, visible.minY + 8)
        XCTAssertLessThanOrEqual(result.maxX, visible.maxX - 8)
        XCTAssertLessThanOrEqual(result.maxY, visible.maxY - 8)
    }

    func testPanelMovedFromDisconnectedDisplayReturnsOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let frame = NSRect(x: 2_400, y: 1_000, width: 380, height: 600)

        let result = FloatingPanelGeometry.constrained(frame, to: visible)

        XCTAssertEqual(result.maxX, visible.maxX - 8)
        XCTAssertEqual(result.maxY, visible.maxY - 8)
    }
}
