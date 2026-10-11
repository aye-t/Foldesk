import Foundation
import FoldeskShared
import XCTest

final class FinderSyncPackagingTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testFinderExtensionMetadataMatchesHostAndUsesCorrectExtensionPoint() throws {
        let host = try plist(at: repositoryRoot.appendingPathComponent("Resources/Info.plist"))
        let finder = try plist(at: repositoryRoot.appendingPathComponent("Sources/FoldeskFinderSync/Info.plist"))
        let extensionDictionary = try XCTUnwrap(finder["NSExtension"] as? [String: Any])

        XCTAssertEqual(finder["CFBundleIdentifier"] as? String, "com.foldesk.mac.findersync")
        XCTAssertEqual(finder["CFBundleVersion"] as? String, host["CFBundleVersion"] as? String)
        XCTAssertEqual(finder["CFBundleShortVersionString"] as? String, host["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(extensionDictionary["NSExtensionPointIdentifier"] as? String, "com.apple.FinderSync")
        XCTAssertEqual(extensionDictionary["NSExtensionPrincipalClass"] as? String, "FoldeskFinderSync.FinderSyncExtension")
    }

    func testFinderExtensionIsSandboxedWithMonitoredFolderAccessAndBuildUsesNSExtensionMain() throws {
        let entitlements = try plist(at: repositoryRoot.appendingPathComponent("Sources/FoldeskFinderSync/FinderSync.entitlements"))
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-write"] as? [String], ["/"])
        XCTAssertEqual(entitlements["com.apple.security.temporary-exception.files.absolute-path.read-write"] as? [String], ["/Volumes/"])

        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("Native/FoldeskNative.xcodeproj"))
        XCTAssertTrue(script.contains("xcodebuild"))
        XCTAssertFalse(script.contains("xcrun swiftc"))
        XCTAssertTrue(script.contains("PlugIns"))
        XCTAssertTrue(script.contains("FinderSync.entitlements"))
    }

    func testNewFilePathDoesNotActivateFinderOrAssociatedApplications() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/FoldeskFinderSync/FinderSyncExtension.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func createNewFile"))
        let end = try XCTUnwrap(source.range(of: "// MARK: - Clipboard", range: start.upperBound..<source.endIndex))
        let createImplementation = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(createImplementation.contains("FoldeskNewFileCreator.create"))
        XCTAssertFalse(createImplementation.contains("NSWorkspace"))
        XCTAssertFalse(createImplementation.contains("activateFileViewerSelecting"))
        XCTAssertFalse(source.contains("directoryURLs = nil"))
        XCTAssertTrue(source.contains("startAccessingSecurityScopedResource"))
        XCTAssertFalse(source.contains("NSMenuItem(title: \"Foldesk\""), "右键第一层不应再套 Foldesk 子菜单")
        XCTAssertFalse(source.contains("representedObject"), "Finder 会丢弃自定义 representedObject")
        XCTAssertFalse(source.contains("item.target = self"), "Finder Sync 动作应由 Finder 转交给 principal object")
        XCTAssertFalse(source.contains("final class FinderSyncExtension"), "扩展主类应与 Xcode Finder Sync 模板一致，允许系统动态调度")
        XCTAssertFalse(source.contains("item.tag ="), "动作不应依赖跨进程菜单 tag")
        XCTAssertTrue(source.contains("#selector(createDocx(_:))"))
        XCTAssertTrue(source.contains("let directory = pendingDirectory ?? currentTargetDirectory()"), "新建文件必须优先使用菜单打开时的目标目录")
        XCTAssertTrue(source.contains("return pendingDirectory"), "动作上下文缺失时必须回退到菜单生成时缓存的目录")
    }

    private func plist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }
}
