import Foundation
@testable import Foldesk
import XCTest

final class ServicesHandlerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoldeskServicesTests-(UUID().uuidString)", isDirectory: true)
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
}
