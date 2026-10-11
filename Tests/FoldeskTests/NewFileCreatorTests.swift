import Foundation
import FoldeskShared
import XCTest

final class NewFileCreatorTests: XCTestCase {
    private var root: URL!
    private var target: URL!
    private var templates: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoldeskNewFileTests-\(UUID().uuidString)", isDirectory: true)
        target = root.appendingPathComponent("target", isDirectory: true)
        templates = root.appendingPathComponent("templates", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)

        let repositoryTemplates = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Foldesk/Resources/Templates", isDirectory: true)
        for name in ["Empty.docx", "Empty.xlsx", "Empty.pptx"] {
            try FileManager.default.copyItem(
                at: repositoryTemplates.appendingPathComponent(name),
                to: templates.appendingPathComponent(name)
            )
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        target = nil
        templates = nil
    }

    func testEveryAdvertisedTypeCreatesExactlyOneFileWithoutOpeningAnApp() throws {
        for kind in FoldeskNewFileKind.allCases {
            let created = try FoldeskNewFileCreator.create(kind, in: target, templatesDirectory: templates)
            XCTAssertEqual(created.pathExtension, kind.fileExtension)
            XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))

            let data = try Data(contentsOf: created)
            if kind.templateFileName != nil {
                XCTAssertGreaterThan(data.count, 100)
                XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4b], "Office 文件必须是真实的 ZIP/OOXML 文档")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).count, FoldeskNewFileKind.allCases.count)
    }

    func testExistingNameIsNeverOverwritten() throws {
        let original = target.appendingPathComponent("未命名.txt")
        try Data("keep".utf8).write(to: original)

        let created = try FoldeskNewFileCreator.create(.txt, in: target, templatesDirectory: templates)

        XCTAssertEqual(created.lastPathComponent, "未命名 2.txt")
        XCTAssertEqual(try Data(contentsOf: original), Data("keep".utf8))
    }

    func testMissingOfficeTemplateFailsWithoutCreatingCorruptDocument() throws {
        try FileManager.default.removeItem(at: templates.appendingPathComponent("Empty.docx"))

        XCTAssertThrowsError(try FoldeskNewFileCreator.create(.docx, in: target, templatesDirectory: templates))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testStructuredTextFilesContainValidStartingContent() throws {
        let json = try FoldeskNewFileCreator.create(.json, in: target, templatesDirectory: templates)
        let html = try FoldeskNewFileCreator.create(.html, in: target, templatesDirectory: templates)
        let xml = try FoldeskNewFileCreator.create(.xml, in: target, templatesDirectory: templates)

        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: json)))
        XCTAssertTrue(try String(contentsOf: html, encoding: .utf8).contains("<meta charset=\"utf-8\">"))
        XCTAssertTrue(try String(contentsOf: xml, encoding: .utf8).hasPrefix("<?xml"))
    }
}
