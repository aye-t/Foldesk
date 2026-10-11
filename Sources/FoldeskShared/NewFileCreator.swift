import Foundation

/// Foldesk 在 Finder「新建文件」菜单中提供的文件类型。
/// Office Open XML 文件必须从真实模板复制，不能伪造成 0 字节文件。
public enum FoldeskNewFileKind: String, CaseIterable, Codable, Sendable {
    case docx
    case xlsx
    case pptx
    case rtf
    case txt
    case markdown = "md"
    case csv
    case json
    case html
    case xml
    case empty

    public var menuTitle: String {
        switch self {
        case .docx: "Microsoft Word 文档 (.docx)"
        case .xlsx: "Microsoft Excel 工作簿 (.xlsx)"
        case .pptx: "Microsoft PowerPoint 演示文稿 (.pptx)"
        case .rtf: "富文本文档 (.rtf)"
        case .txt: "文本文档 (.txt)"
        case .markdown: "Markdown 文档 (.md)"
        case .csv: "CSV 表格 (.csv)"
        case .json: "JSON 文件 (.json)"
        case .html: "HTML 网页 (.html)"
        case .xml: "XML 文件 (.xml)"
        case .empty: "空文件（无扩展名）"
        }
    }

    public var defaultBaseName: String { "未命名" }

    public var fileExtension: String {
        self == .empty ? "" : rawValue
    }

    public var templateFileName: String? {
        switch self {
        case .docx, .xlsx, .pptx: "Empty.\(rawValue)"
        default: nil
        }
    }

    public var initialContents: Data {
        switch self {
        case .rtf:
            Data("{\\rtf1\\ansi\\deff0\n}\n".utf8)
        case .json:
            Data("{}\n".utf8)
        case .html:
            Data("<!doctype html>\n<html lang=\"zh-CN\">\n<head>\n  <meta charset=\"utf-8\">\n  <title></title>\n</head>\n<body>\n</body>\n</html>\n".utf8)
        case .xml:
            Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root></root>\n".utf8)
        default:
            Data()
        }
    }
}

public enum FoldeskNewFileError: LocalizedError, Sendable {
    case targetIsNotDirectory(String)
    case templateMissing(String)
    case unableToCreate(String)

    public var errorDescription: String? {
        switch self {
        case .targetIsNotDirectory(let path):
            "目标位置不是可用的文件夹：\(path)"
        case .templateMissing(let name):
            "缺少内置模板：\(name)。已停止创建，未生成损坏文件。"
        case .unableToCreate(let detail):
            "无法新建文件：\(detail)"
        }
    }
}

/// 与 UI/宿主应用无关的文件创建核心。成功后只返回文件 URL，不打开任何应用，
/// 也不激活 Finder；调用方可据此保持 Windows 风格的“先创建、后手动打开”。
public enum FoldeskNewFileCreator {
    @discardableResult
    public static func create(
        _ kind: FoldeskNewFileKind,
        in directory: URL,
        templatesDirectory: URL
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FoldeskNewFileError.targetIsNotDirectory(directory.path)
        }

        let templateURL: URL?
        if let templateFileName = kind.templateFileName {
            let candidate = templatesDirectory.appendingPathComponent(templateFileName)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw FoldeskNewFileError.templateMissing(templateFileName)
            }
            templateURL = candidate
        } else {
            templateURL = nil
        }

        // 逐个尝试候选名，既避免覆盖，也处理两个进程同时点击“新建”的竞态。
        for index in 1...10_000 {
            let name = candidateName(for: kind, index: index)
            let destination = directory.appendingPathComponent(name)
            do {
                if let templateURL {
                    try FileManager.default.copyItem(at: templateURL, to: destination)
                } else {
                    try kind.initialContents.write(to: destination, options: .withoutOverwriting)
                }
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw FoldeskNewFileError.unableToCreate(error.localizedDescription)
            }
        }

        throw FoldeskNewFileError.unableToCreate("同名文件过多")
    }

    public static func candidateName(for kind: FoldeskNewFileKind, index: Int) -> String {
        let suffix = index <= 1 ? "" : " \(index)"
        let base = kind.defaultBaseName + suffix
        return kind.fileExtension.isEmpty ? base : "\(base).\(kind.fileExtension)"
    }
}
