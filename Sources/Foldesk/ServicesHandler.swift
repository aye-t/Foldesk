import AppKit
import Foundation

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
           let src = Bundle.main.url(forResource: template, withExtension: ext, subdirectory: "Templates") {
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                created = true
            } catch {
                created = false
            }
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
