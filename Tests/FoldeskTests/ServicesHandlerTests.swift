import Foundation
import FoldeskShared
@testable import Foldesk
import XCTest

final class ServicesHandlerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoldeskServicesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testCreateFileDoesNotOverwriteSameName() throws {
        let first = try XCTUnwrap(
            FoldeskServices.createFile(
                template: nil,
                ext: "txt",
                defaultBase: "未命名",
                in: temporaryDirectory,
                revealInFinder: false
            )
        )
        let second = try XCTUnwrap(
            FoldeskServices.createFile(
                template: nil,
                ext: "txt",
                defaultBase: "未命名",
                in: temporaryDirectory,
                revealInFinder: false
            )
        )

        XCTAssertEqual(first.lastPathComponent, "未命名.txt")
        XCTAssertEqual(second.lastPathComponent, "未命名 2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testCompressAndExtractRoundTrip() throws {
        let source = temporaryDirectory.appendingPathComponent("测试文档.txt")
        try Data("Foldesk archive probe".utf8).write(to: source)

        let archive = try XCTUnwrap(FoldeskServices.compress([source]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let extractedDirectory = try XCTUnwrap(FoldeskServices.extract([archive]).first)
        let extractedFile = extractedDirectory.appendingPathComponent(source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: extractedFile), Data("Foldesk archive probe".utf8))
    }

    func testCompressesDirectoryRecursively() throws {
        let sourceDirectory = temporaryDirectory.appendingPathComponent("资料", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let nestedFile = sourceDirectory.appendingPathComponent("内容.md")
        try Data("# Foldesk".utf8).write(to: nestedFile)

        let archive = try XCTUnwrap(FoldeskServices.compress([sourceDirectory]))
        let extractedDirectory = try XCTUnwrap(FoldeskServices.extract([archive]).first)
        let extractedFile = extractedDirectory
            .appendingPathComponent(sourceDirectory.lastPathComponent, isDirectory: true)
            .appendingPathComponent(nestedFile.lastPathComponent)

        XCTAssertEqual(try Data(contentsOf: extractedFile), Data("# Foldesk".utf8))
    }

    func testCopyAndMoveUseConfiguredSlotAndAvoidOverwriting() throws {
        let sourceDirectory = temporaryDirectory.appendingPathComponent("来源", isDirectory: true)
        let targetDirectory = temporaryDirectory.appendingPathComponent("目标", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("资料.txt")
        try Data("first".utf8).write(to: source)
        try Data("existing".utf8).write(to: targetDirectory.appendingPathComponent("资料.txt"))

        let config = FinderSyncConfig(
            enabled: true,
            favoriteDirs: [FavoriteDir(name: "目标", path: targetDirectory.path)],
            newFileTemplates: [:],
            features: Features(),
            openWithApps: []
        )
        let copyResult = FoldeskServices.copyOrMove([source], toDirIndex: 0, move: false, config: config)

        XCTAssertTrue(copyResult.isSuccess)
        XCTAssertEqual(copyResult.destinations.first?.lastPathComponent, "资料 2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let moveResult = FoldeskServices.copyOrMove([source], toDirIndex: 0, move: true, config: config)
        XCTAssertTrue(moveResult.isSuccess)
        XCTAssertEqual(moveResult.destinations.first?.lastPathComponent, "资料 3.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testMissingFavoriteSlotReturnsActionableError() throws {
        let source = temporaryDirectory.appendingPathComponent("资料.txt")
        try Data().write(to: source)
        let config = FinderSyncConfig(
            enabled: true,
            favoriteDirs: [],
            newFileTemplates: [:],
            features: Features(),
            openWithApps: []
        )

        let result = FoldeskServices.copyOrMove([source], toDirIndex: 0, move: false, config: config)

        XCTAssertEqual(result.failedItems, [source])
        XCTAssertTrue(result.errorMessage?.contains("尚未配置") == true)
    }

    func testOfficeTemplatesAreRealDocumentsAndMissingTemplateFails() throws {
        for ext in ["xlsx", "docx", "pptx"] {
            let document = try XCTUnwrap(FoldeskServices.createFile(
                template: "Empty", ext: ext, defaultBase: "模板", in: temporaryDirectory, revealInFinder: false
            ))
            let data = try Data(contentsOf: document)
            XCTAssertGreaterThan(data.count, 100)
            XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4b])
        }
        XCTAssertNil(FoldeskServices.createFile(
            template: "Missing", ext: "docx", defaultBase: "不应生成", in: temporaryDirectory, revealInFinder: false
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("不应生成.docx").path))
    }

    func testArchiveSupportsDashLeadingFilenameAndReportsPartialExtraction() throws {
        let source = temporaryDirectory.appendingPathComponent("-文件 空格.txt")
        try Data("fixture".utf8).write(to: source)
        let archive = try XCTUnwrap(FoldeskServices.compress([source]))
        let corrupt = temporaryDirectory.appendingPathComponent("损坏.zip")
        try Data("not a zip".utf8).write(to: corrupt)
        let result = FoldeskServices.extractResult([archive, corrupt, source])
        XCTAssertEqual(result.destinations.count, 1)
        XCTAssertEqual(result.failedItems, [corrupt, source])
        XCTAssertNotNil(result.errorMessage)
        XCTAssertFalse(result.isSuccess)
        let restored = try XCTUnwrap(result.destinations.first).appendingPathComponent(source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: restored), Data("fixture".utf8))
    }
}
