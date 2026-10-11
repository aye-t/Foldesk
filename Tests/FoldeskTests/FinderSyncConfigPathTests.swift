import Foundation
import FoldeskShared
@testable import Foldesk
import XCTest

/// 回归测试：主程序与 Finder Sync 扩展必须落在同一份配置上，且扩展不能在
/// 自己的沙盒容器里找用户目录。
///
/// 背景（2026-10-11 修复）：扩展是沙盒进程，`FileManager` 给出的“用户目录”
/// 是 `~/Library/Containers/<bundle-id>/Data`。此前 `configURL` 由
/// `.applicationSupportDirectory` 推导，于是扩展读容器、主程序写真实路径，
/// 表现为“设置页怎么改，右键菜单都不变”。
final class FinderSyncConfigPathTests: XCTestCase {

    // MARK: - 配置路径

    func testConfigURLIsNotInsideSandboxContainer() {
        let path = FinderSyncConfig.configURL.path
        XCTAssertFalse(
            path.contains("/Library/Containers/"),
            "配置路径落在沙盒容器里，扩展将永远读不到用户配置：\(path)"
        )
    }

    func testConfigURLPointsAtTheSharedLocation() {
        let path = FinderSyncConfig.configURL.path
        XCTAssertTrue(
            path.hasSuffix("/Library/Application Support/Foldesk/findersync.json"),
            "配置路径不符合预期：\(path)"
        )
    }

    func testRealHomeDirectoryIsAUsableDirectory() {
        let home = FinderSyncConfig.realHomeDirectoryPath
        XCTAssertFalse(home.contains("/Library/Containers/"), "真实主目录不能是容器：\(home)")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory),
            "真实主目录不存在：\(home)"
        )
        XCTAssertTrue(isDirectory.boolValue, "真实主目录不是目录：\(home)")
    }

    func testDefaultFavoriteDirectoriesUseRealHome() {
        let dirs = FinderSyncConfig.default.favoriteDirs
        XCTAssertEqual(dirs.count, 3, "默认应为下载 / 桌面 / 文稿三项")
        for dir in dirs {
            XCTAssertFalse(
                dir.path.contains("/Library/Containers/"),
                "默认常用目录落在容器里：\(dir.path)"
            )
            XCTAssertTrue(
                dir.path.hasPrefix(FinderSyncConfig.realHomeDirectoryPath),
                "默认常用目录未基于真实主目录：\(dir.path)"
            )
        }
    }

    func testConfigRoundTripsThroughExplicitURL() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foldesk-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var config = FinderSyncConfig.default
        config.favoriteDirs = [FavoriteDir(name: "测试目录", path: "/tmp")]
        config.newFileTemplates["rtf"] = false
        try config.save(to: url)

        let loaded = try FinderSyncConfig.load(from: url)
        XCTAssertEqual(loaded.favoriteDirs.first?.path, "/tmp")
        XCTAssertEqual(loaded.newFileTemplates["rtf"], false)
    }

    func testMissingNewFileTemplateKeysFallBackToEnabled() throws {
        // 旧版配置可能只存了部分类型。扩展用 `?? true` 兜底，新增类型不应
        // 因为旧配置缺键而从菜单里消失。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foldesk-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"enabled":true,"newFileTemplates":{"docx":false}}"#.utf8).write(to: url)

        let loaded = try FinderSyncConfig.load(from: url)
        XCTAssertEqual(loaded.newFileTemplates["docx"], false)
        XCTAssertNil(loaded.newFileTemplates["rtf"])
        XCTAssertTrue(loaded.newFileTemplates["rtf"] ?? true, "缺失键应回退为启用")
    }

    // MARK: - 扩展菜单入口的并发纪律

    /// Finder 在它自己的 XPC 队列上调用菜单 selector，而 Swift 6 会把带
    /// `@IBAction` 的方法隐式视为 `@MainActor`。入口一旦不是 `nonisolated`，
    /// 点击时就会命中 `dispatch_assert_queue` 断言、整个扩展进程被终止 ——
    /// 用户看到的是“点了没反应”。这里用源码扫描把它钉住，防止回归。
    func testEveryFinderMenuActionIsNonisolated() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FoldeskTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 包根目录
            .appendingPathComponent("Sources/FoldeskFinderSync/FinderSyncExtension.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        let declarations = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("@IBAction ") }

        XCTAssertGreaterThanOrEqual(
            declarations.count, 25,
            "读到的右键动作声明少于预期，源码路径可能已变更"
        )
        for declaration in declarations {
            XCTAssertTrue(
                declaration.contains("nonisolated"),
                "右键动作入口缺少 nonisolated，点击会导致扩展进程被终止：\(declaration)"
            )
        }
    }

    /// 沙盒里 `FileManager` 的“用户目录”是容器。扩展源码中任何直接用它的地方
    /// 都会把文件写到用户看不到的位置（例如“发送替身到桌面”）。
    func testExtensionDoesNotUseSandboxHomeShortcut() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FoldeskFinderSync/FinderSyncExtension.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        // 只看真正的代码行：注释里会特意写出这些 API 的名字来解释为什么不能用。
        let codeLines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }

        for forbidden in ["homeDirectoryForCurrentUser", "NSHomeDirectory()", "applicationSupportDirectory"] {
            let offenders = codeLines.filter { $0.contains(forbidden) }
            XCTAssertTrue(
                offenders.isEmpty,
                "扩展源码不应再直接使用 \(forbidden)（沙盒下它指向扩展容器）。命中：\(offenders.joined(separator: " | "))"
            )
        }
    }
}
