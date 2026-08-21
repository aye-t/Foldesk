import AppKit
import Foundation
import FoldeskShared

/// 右键「服务」(NSServices) 的动作实现。
/// 这些动作通过 app 的 Info.plist 中声明的 NSServices 注册到访达右键 → 服务 子菜单，
/// 无需公证 / 开发者证书即可被系统发现，是 Finder Sync 扩展在自签环境下的可用替代。
enum FoldeskServices {

    // MARK: - 当前访达目录

    /// 通过独立的 osascript 进程取访达最前窗口所在目录；失败回退桌面。
    /// 不使用 NSAppleScript，避免服务回调在主线程触发 Apple Event 性能诊断。
    static func currentFinderFolder() -> URL {
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", src]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
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
            // The desktop fallback below keeps the service usable if Finder
            // automation is unavailable or the user denies the permission.
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    // MARK: - 新建文件

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
        if let template,
           let src = Self.templateURL(named: template, ext: ext) {
            created = (try? FileManager.default.copyItem(at: src, to: dest)) != nil
        } else {
            created = FileManager.default.createFile(atPath: dest.path, contents: nil)
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

    @MainActor static func copyPaths(_ urls: [URL]) {
        let text = urls.map(\.path).joined(separator: "\n")
        writePasteboard(text)
    }

    @MainActor static func copyNames(_ urls: [URL]) {
        let text = urls.map { $0.lastPathComponent }.joined(separator: "\n")
        writePasteboard(text)
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
        proc.arguments = ["-q", "-r", zipURL.path] + urls.map { url in
            url.deletingLastPathComponent() == parent ? url.lastPathComponent : url.path
        }
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: zipURL.path) else { return nil }
        return zipURL
    }

    @discardableResult
    static func extract(_ urls: [URL]) -> [URL] {
        var destinations: [URL] = []
        for url in urls where url.pathExtension.lowercased() == "zip" {
            let dest = uniqueDirURL(in: url.deletingLastPathComponent(), base: url.deletingPathExtension().lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            } catch {
                continue
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", url.path, dest.path]
            do {
                try proc.run()
            } catch {
                try? FileManager.default.removeItem(at: dest)
                continue
            }
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                destinations.append(dest)
            } else {
                try? FileManager.default.removeItem(at: dest)
            }
        }
        return destinations
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

    /// 将选中的文件复制或移动到第 `index` 个常用目录。返回成功处理的个数。
    @discardableResult
    static func copyOrMove(_ urls: [URL], toDirIndex index: Int, move: Bool) -> Int {
        let cfg = FinderSyncConfig.load()
        guard cfg.favoriteDirs.indices.contains(index) else { return 0 }
        let dir = expand(cfg.favoriteDirs[index].path)
        guard (try? dir.checkResourceIsReachable()) == true else { return 0 }
        var done = 0
        for u in urls {
            let dest = uniqueDestination(in: dir, for: u)
            do {
                if move { try FileManager.default.moveItem(at: u, to: dest) }
                else { try FileManager.default.copyItem(at: u, to: dest) }
                done += 1
            } catch { continue }
        }
        return done
    }

    // MARK: - 用指定 App 打开

    /// 用第 `index` 个预设 App 打开选中的文件。App 未安装则退化为系统默认打开。
    @MainActor static func openWith(_ urls: [URL], appIndex index: Int) {
        guard !urls.isEmpty else { return }
        let cfg = FinderSyncConfig.load()
        guard cfg.openWithApps.indices.contains(index) else { return }
        let bundleId = cfg.openWithApps[index].bundleId
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            for u in urls { NSWorkspace.shared.open(u) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error { NSLog("Foldesk: 用指定 App 打开失败: \(error.localizedDescription)") }
        }
    }

    // MARK: - 彻底删除（二次确认）

    @MainActor static func permanentDelete(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "彻底删除 1 个项目？"
            : "彻底删除 \(urls.count) 个项目？"
        alert.informativeText = "将直接删除，不进入废纸篓，无法恢复。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            for u in urls {
                try? FileManager.default.removeItem(at: u)
            }
        }
    }

    // MARK: - 工具

    @MainActor private static func writePasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
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
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
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
