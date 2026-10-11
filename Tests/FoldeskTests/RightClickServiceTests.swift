import AppKit
import Foundation
import FoldeskShared
@testable import Foldesk
import XCTest

@MainActor
final class RightClickServiceTests: XCTestCase {
    func testLaunchModeDistinguishesUserLaunchFromServiceLaunch() {
        let userLaunch = Notification(
            name: NSApplication.didFinishLaunchingNotification,
            userInfo: [NSApplication.launchIsDefaultUserInfoKey: NSNumber(value: true)]
        )
        let serviceLaunch = Notification(
            name: NSApplication.didFinishLaunchingNotification,
            userInfo: [NSApplication.launchIsDefaultUserInfoKey: NSNumber(value: false)]
        )

        XCTAssertTrue(FoldeskAppDelegate.isDefaultLaunch(userLaunch))
        XCTAssertFalse(FoldeskAppDelegate.isDefaultLaunch(serviceLaunch))
    }

    func testInfoPlistDeclaresTwentyFiveUniqueCallableServices() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = repositoryRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        let messages = try services.map { service in
            try XCTUnwrap(service["NSMessage"] as? String)
        }

        XCTAssertEqual(services.count, 25)
        XCTAssertEqual(Set(messages).count, 25)

        let newFileServices = services.filter {
            ($0["NSMessage"] as? String)?.hasPrefix("foldNew") == true
        }
        XCTAssertEqual(newFileServices.count, FoldeskNewFileKind.allCases.count)
        for service in newFileServices {
            let menu = try XCTUnwrap(service["NSMenuItem"] as? [String: String])
            XCTAssertTrue(menu["default"]?.contains("在此新建") == true)
            XCTAssertNil(service["NSSendTypes"], "新建服务不应要求或打开输入文件")
        }
        for service in services {
            let context = try XCTUnwrap(service["NSRequiredContext"] as? [String: String])
            XCTAssertEqual(context["NSApplicationIdentifier"], "com.apple.finder")
            XCTAssertNil(context["NSServicesApplicationIdentifier"])
            if let types = service["NSSendTypes"] as? [String] {
                XCTAssertTrue(types.contains("public.file-url"))
                XCTAssertEqual(service["NSSendFileTypes"] as? [String], ["public.item"])
            }
        }

        let delegate = FoldeskAppDelegate()
        for message in messages {
            let selector = NSSelectorFromString("\(message):userData:error:")
            XCTAssertTrue(delegate.responds(to: selector), "缺少服务回调：\(selector)")
        }
    }

    func testConfigRoundTripPreservesLegacyEntriesBeyondStaticSlots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoldeskConfigTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("findersync.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let directories = (1...5).map { FavoriteDir(name: "目录 \($0)", path: "/tmp/\($0)") }
        let applications = (1...5).map { OpenWithApp(name: "App \($0)", bundleId: "example.app.\($0)") }
        let config = FinderSyncConfig(
            enabled: true,
            favoriteDirs: directories,
            newFileTemplates: ["txt": true],
            features: Features(),
            openWithApps: applications
        )

        try config.save(to: url)
        let loaded = try FinderSyncConfig.load(from: url)

        XCTAssertEqual(loaded.favoriteDirs, directories)
        XCTAssertEqual(loaded.openWithApps, applications)
        XCTAssertEqual(FinderSyncConfig.serviceSlotLimit, 3)
    }

    func testCorruptConfigDoesNotFallBackToDefaultDestinations() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        XCTAssertEqual(try FinderSyncConfig.loadForServices(from: url).favoriteDirs.count, 3)
        let broken = Data("{broken".utf8)
        try broken.write(to: url)
        XCTAssertThrowsError(try FinderSyncConfig.loadForServices(from: url))
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testEmptySelectionReturnsNSStringServiceError() {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var message: NSString?
        FoldeskAppDelegate().foldCopyPath(pasteboard, userData: nil, error: &message)
        XCTAssertEqual(message as String?, FoldeskServiceError.noSelection.localizedDescription)
    }
}
