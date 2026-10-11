import AppKit
import Foundation
import FoldeskShared

enum FoldeskServiceError: LocalizedError, Sendable {
    case noSelection
    case finderFolderUnavailable(String)
    case targetNotConfigured(Int)
    case targetUnavailable(String)
    case applicationNotConfigured(Int)
    case applicationUnavailable(String)
    case configurationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return "没有收到访达选中的文件。"
        case .finderFolderUnavailable(let detail):
            return "无法读取当前访达目录。\(detail.isEmpty ? "" : "\n\(detail)")"
        case .targetNotConfigured(let slot):
            return "常用目录 \(slot) 尚未配置。"
        case .targetUnavailable(let path):
            return "目标目录不可用或不可写：\(path)"
        case .applicationNotConfigured(let slot):
            return "指定 App \(slot) 尚未配置。"
        case .applicationUnavailable(let app):
            return "找不到或无法使用指定 App：\(app)"
        case .configurationUnavailable(let detail):
            return "无法读取右键服务配置，操作已停止，未使用默认目录或 App。\n\(detail)"
        }
    }
}

struct FoldeskFileOperationResult: Sendable {
    var destinations: [URL] = []
    var failedItems: [URL] = []
    var errorMessage: String?

    var isSuccess: Bool { !destinations.isEmpty && failedItems.isEmpty && errorMessage == nil }
}

struct FoldeskDeleteResult: Sendable {
    var deletedItems: [URL] = []
    var failedItems: [URL] = []
    var cancelled = false
}

/// 右键「服务」(NSServices) 的动作实现。
/// 这些动作通过 app 的 Info.plist 中声明的 NSServices 注册到访达右键 → 服务 子菜单，
/// 无需公证 / 开发者证书即可被系统发现，是 Finder Sync 扩展在自签环境下的可用替代。
enum FoldeskServices {

    // MARK: - 当前访达目录

    /// 通过独立的 osascript 进程取访达最前窗口所在目录。
    /// 不使用 NSAppleScript，避免服务回调在主线程触发 Apple Event 性能诊断。
    static func currentFinderFolder() throws -> URL {
        let src = """
        tell application "Finder"
            if (count of windows) > 0 then
                get POSIX path of (target of front window as alias)
            else
                get POSIX path of (desktop as alias)
            end if
        end tell
        """
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", src]
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus == 0,
               let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        } catch {
            throw FoldeskServiceError.finderFolderUnavailable(error.localizedDescription)
        }
        let detail = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw FoldeskServiceError.finderFolderUnavailable(detail)
    }

    // MARK: - 新建文件

    /// Finder 扩展和 NSServices 共用同一份类型目录与创建核心。
    @discardableResult
    static func createFile(
        kind: FoldeskNewFileKind,
        in folder: URL,
        revealInFinder: Bool = false
    ) -> URL? {
        let templatesDirectory = templateDirectoryURL() ?? folder
        guard let destination = try? FoldeskNewFileCreator.create(
            kind,
            in: folder,
            templatesDirectory: templatesDirectory
        ) else { return nil }
        if revealInFinder {
            Task { @MainActor in
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
        return destination
    }

    /// 在指定目录新建文件。template 为模板资源名（不含扩展名），nil 表示创建空文件。
    @discardableResult
    static func createFile(
        template: String?,
        ext: String,
        defaultBase: String,
        in folder: URL,
        revealInFinder: Bool = true
    ) -> URL? {
        let dest = uniqueFileURL(in: folder, base: defaultBase, ext: ext)
        let created: Bool
        if let template {
            guard let src = Self.templateURL(named: template, ext: ext) else { return nil }
            created = (try? FileManager.default.copyItem(at: src, to: dest)) != nil
        } else {
            created = (try? Data().write(to: dest, options: .withoutOverwriting)) != nil
        }
        guard created else { return nil }
        if revealInFinder {
            Task { @MainActor in
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        }
        return dest
    }

    // MARK: - 复制路径 / 文件名

    @discardableResult
    @MainActor static func copyPaths(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let text = urls.map(\.path).joined(separator: "\n")
        writePasteboard(text)
        return true
    }

    @discardableResult
    @MainActor static func copyNames(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let text = urls.map { $0.lastPathComponent }.joined(separator: "\n")
        writePasteboard(text)
        return true
    }

    // MARK: - 压缩 / 解压

    @discardableResult
    static func compress(_ urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        let parent = first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Foldesk归档"
        let zipURL = uniqueFileURL(in: parent, base: base, ext: "zip")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = parent
        proc.arguments = ["-q", "-r", zipURL.path, "--"] + urls.map { url in
            url.deletingLastPathComponent() == parent ? "./" + url.lastPathComponent : url.path
        }
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: zipURL.path) else {
            try? FileManager.default.removeItem(at: zipURL)
            return nil
        }
        return zipURL
    }

    @discardableResult
    static func extract(_ urls: [URL]) -> [URL] {
        extractResult(urls).destinations
    }

    static func extractResult(_ urls: [URL]) -> FoldeskFileOperationResult {
        var result = FoldeskFileOperationResult()
        for url in urls {
            guard url.pathExtension.lowercased() == "zip" else {
                result.failedItems.append(url)
                continue
            }
            let dest = uniqueDirURL(in: url.deletingLastPathComponent(), base: url.deletingPathExtension().lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            } catch {
                result.failedItems.append(url)
                continue
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", url.path, dest.path]
            do {
                try proc.run()
            } catch {
                try? FileManager.default.removeItem(at: dest)
                result.failedItems.append(url)
                continue
            }
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                result.destinations.append(dest)
            } else {
                try? FileManager.default.removeItem(at: dest)
                result.failedItems.append(url)
            }
        }
        if urls.isEmpty || !result.failedItems.isEmpty {
            result.errorMessage = "已解压 \(result.destinations.count) 项，失败 \(result.failedItems.count) 项。请检查是否为有效的 zip 文件及目录写入权限。"
        }
        return result
    }

    // MARK: - 常用目录：复制 / 移动

    /// 把 `~` 展开为绝对路径。
    private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// 在目标目录内为文件算出不与现有文件冲突的目标路径（保留原名）。
    private static func uniqueDestination(in dir: URL, for file: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(file.lastPathComponent)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            let ext = file.pathExtension
            let base = file.deletingPathExtension().lastPathComponent
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidate = dir.appendingPathComponent(name)
            i += 1
        }
        return candidate
    }

    /// 将选中的文件复制或移动到第 `index` 个常用目录。
    @discardableResult
    static func copyOrMove(
        _ urls: [URL],
        toDirIndex index: Int,
        move: Bool,
        config suppliedConfig: FinderSyncConfig? = nil
    ) -> FoldeskFileOperationResult {
        guard !urls.isEmpty else {
            return FoldeskFileOperationResult(errorMessage: FoldeskServiceError.noSelection.localizedDescription)
        }
        let config: FinderSyncConfig
        do {
            config = try suppliedConfig ?? FinderSyncConfig.loadForServices()
        } catch {
            return FoldeskFileOperationResult(
                failedItems: urls,
                errorMessage: FoldeskServiceError.configurationUnavailable(error.localizedDescription).localizedDescription
            )
        }
        guard config.favoriteDirs.indices.contains(index) else {
            return FoldeskFileOperationResult(
                failedItems: urls,
                errorMessage: FoldeskServiceError.targetNotConfigured(index + 1).localizedDescription
            )
        }
        let dir = expand(config.favoriteDirs[index].path)
        let values = try? dir.resourceValues(forKeys: [.isDirectoryKey])
        guard (try? dir.checkResourceIsReachable()) == true,
              values?.isDirectory == true,
              FileManager.default.isWritableFile(atPath: dir.path) else {
            return FoldeskFileOperationResult(
                failedItems: urls,
                errorMessage: FoldeskServiceError.targetUnavailable(dir.path).localizedDescription
            )
        }
        var result = FoldeskFileOperationResult()
        for u in urls {
            let dest = uniqueDestination(in: dir, for: u)
            do {
                if move { try FileManager.default.moveItem(at: u, to: dest) }
                else { try FileManager.default.copyItem(at: u, to: dest) }
                result.destinations.append(dest)
            } catch {
                result.failedItems.append(u)
            }
        }
        if !result.failedItems.isEmpty {
            result.errorMessage = "已完成 \(result.destinations.count) 项，失败 \(result.failedItems.count) 项。"
        }
        return result
    }

    // MARK: - 用指定 App 打开

    /// 用第 `index` 个预设 App 打开选中的文件。
    @MainActor static func openWith(
        _ urls: [URL],
        appIndex index: Int,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        guard !urls.isEmpty else {
            completion(FoldeskServiceError.noSelection)
            return
        }
        let cfg: FinderSyncConfig
        do {
            cfg = try FinderSyncConfig.loadForServices()
        } catch {
            completion(FoldeskServiceError.configurationUnavailable(error.localizedDescription))
            return
        }
        guard cfg.openWithApps.indices.contains(index) else {
            completion(FoldeskServiceError.applicationNotConfigured(index + 1))
            return
        }
        let configuredApp = cfg.openWithApps[index]
        let value = configuredApp.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let appURL: URL? = value.hasPrefix("/")
            ? URL(fileURLWithPath: value, isDirectory: true)
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
        guard let appURL,
              FileManager.default.fileExists(atPath: appURL.path) else {
            completion(FoldeskServiceError.applicationUnavailable(configuredApp.name))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
            Task { @MainActor in completion(error) }
        }
    }

    // MARK: - 彻底删除（二次确认）

    @MainActor static func permanentDelete(_ urls: [URL]) -> FoldeskDeleteResult {
        guard !urls.isEmpty else { return FoldeskDeleteResult() }
        let protected = urls.filter(isProtectedDeletionTarget)
        if !protected.isEmpty {
            return FoldeskDeleteResult(failedItems: protected)
        }
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "彻底删除 1 个项目？"
            : "彻底删除 \(urls.count) 个项目？"
        let names = urls.prefix(5).map(\.lastPathComponent).joined(separator: "、")
        let suffix = urls.count > 5 ? " 等 \(urls.count) 项" : ""
        alert.informativeText = "\(names)\(suffix)\n\n将直接删除，不进入废纸篓，无法恢复。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return FoldeskDeleteResult(cancelled: true)
        }
        var result = FoldeskDeleteResult()
        for u in urls {
            do {
                try FileManager.default.removeItem(at: u)
                result.deletedItems.append(u)
            } catch {
                result.failedItems.append(u)
            }
        }
        return result
    }

    // MARK: - 工具

    @MainActor private static func writePasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func isProtectedDeletionTarget(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let protectedPaths: Set<String> = [
            "/", NSHomeDirectory(), "/Applications", "/Library", "/System", "/Users", "/private"
        ]
        return protectedPaths.contains(path)
    }

    /// 在多个候选位置查找模板文件，覆盖 .app 打包与 `swift build` / Xcode 调试构建，
    /// 确保新建 Excel / Word / PPT 拿到的是真文档，而非 0 字节空文件。
    private static func templateURL(named: String, ext: String) -> URL? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: named, withExtension: ext, subdirectory: "Templates"),
            Bundle.main.resourceURL?.appendingPathComponent("Templates/\(named).\(ext)"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/Templates/\(named).\(ext)"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("Templates/\(named).\(ext)"),
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Foldesk/Resources/Templates/\(named).\(ext)")
        ]
        if let bundled = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return bundled
        }
        // 打包 App 缺模板时直接失败；不要访问可能不存在的 SwiftPM bundle 而崩溃。
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.module.url(forResource: named, withExtension: ext, subdirectory: "Templates")
    }

    private static func templateDirectoryURL() -> URL? {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("Templates", isDirectory: true),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/Templates", isDirectory: true),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("Templates", isDirectory: true),
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Foldesk/Resources/Templates", isDirectory: true),
            Bundle.module.resourceURL?.appendingPathComponent("Templates", isDirectory: true)
        ]
        return candidates.compactMap { $0 }.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static func uniqueFileURL(in folder: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        let name = ext.isEmpty ? base : "\(base).\(ext)"
        var candidate = folder.appendingPathComponent(name)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidate = folder.appendingPathComponent(next)
            i += 1
        }
        return candidate
    }

    private static func uniqueDirURL(in folder: URL, base: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(base)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(i)")
            i += 1
        }
        return candidate
    }

    /// 从服务 pasteboard 读取选中的文件 URL 列表。
    @MainActor static func fileURLs(from pboard: NSPasteboard) -> [URL] {
        if let paths = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        if let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            return urls
        }
        return []
    }
}
