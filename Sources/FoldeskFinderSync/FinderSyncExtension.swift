import AppKit
import FinderSync
import FoldeskShared

/// 右键新建文件请求（菜单项 representedObject 承载）。
final class NewFileRequest: NSObject {
    let fileName: String
    let template: String?   // 资源模板名；nil 表示直接创建空文件（txt/md/empty）
    init(fileName: String, template: String?) {
        self.fileName = fileName
        self.template = template
    }
}

/// 复制/移动到收藏目录请求。
final class CopyMoveRequest: NSObject {
    let destPath: String
    let move: Bool
    init(destPath: String, move: Bool) {
        self.destPath = destPath
        self.move = move
    }
}

final class FinderSyncExtension: FIFinderSync {

    override init() {
        super.init()
        // nil = 监听 Finder 所有目录（含桌面与边栏），使右键菜单处处可用。
        FIFinderSyncController.`default`().directoryURLs = nil
    }

    // MARK: - 菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let cfg = FinderSyncConfig.load()
        guard cfg.enabled else { return nil }

        let menu = NSMenu(title: "")

        menu.addItem(makeNewFileItem(cfg: cfg))
        menu.addItem(makeCopyItem(cfg: cfg, move: false))
        menu.addItem(makeCopyItem(cfg: cfg, move: true))
        if let ow = makeOpenWithItem(cfg: cfg) { menu.addItem(ow) }
        menu.addItem(makeFavoritesOpenItem(cfg: cfg))
        menu.addItem(makeCopyPathItem())
        if cfg.features.copyName { menu.addItem(makeCopyNameItem()) }
        if cfg.features.sendAliasToDesktop { menu.addItem(makeSendAliasItem()) }
        if cfg.features.compress { menu.addItem(makeCompressItem()) }
        if cfg.features.extract { menu.addItem(makeExtractItem()) }
        if cfg.features.permanentDelete { menu.addItem(makePermanentDeleteItem()) }
        menu.addItem(makeAddFavoriteItem())
        menu.addItem(makeHiddenItem(show: true))
        menu.addItem(makeHiddenItem(show: false))
        menu.addItem(makeTerminalItem())

        return menu
    }

    // MARK: - 右键所在目录 / 选中项

    private func controller() -> FIFinderSyncController { FIFinderSyncController.`default`() }

    /// 右键目标目录：点击文件取其父目录，点击文件夹取其本身。
    private func targetDir() -> URL {
        let c = controller()
        let base: URL?
        if let t = c.targetedURL() {
            base = t
        } else if let first = c.selectedItemURLs()?.first {
            base = first
        } else {
            base = nil
        }
        guard let base else { return FileManager.default.homeDirectoryForCurrentUser }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue {
            return base
        }
        return base.deletingLastPathComponent()
    }

    private func selectedURLs() -> [URL] {
        controller().selectedItemURLs() ?? []
    }

    private func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    // MARK: - 菜单项构建

    private func makeNewFileItem(cfg: FinderSyncConfig) -> NSMenuItem {
        let item = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "")
        let entries: [(key: String, title: String, fileName: String, template: String?)] = [
            ("xlsx", "Microsoft Excel 工作簿", "未命名.xlsx", "Empty.xlsx"),
            ("docx", "Microsoft Word 文档", "未命名.docx", "Empty.docx"),
            ("pptx", "Microsoft PowerPoint 演示文稿", "未命名.pptx", "Empty.pptx"),
            ("txt", "文本文档", "未命名.txt", nil),
            ("md", "Markdown", "未命名.md", nil),
            ("empty", "空文件", "未命名", nil)
        ]
        for e in entries where (cfg.newFileTemplates[e.key] ?? false) {
            let mi = NSMenuItem(title: e.title, action: #selector(createNewFile(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = NewFileRequest(fileName: e.fileName, template: e.template)
            sub.addItem(mi)
        }
        if sub.items.isEmpty {
            let none = NSMenuItem(title: "（未启用任何模板）", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        item.submenu = sub
        return item
    }

    private func makeCopyItem(cfg: FinderSyncConfig, move: Bool) -> NSMenuItem {
        let title = move ? "移动到" : "复制到"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "")
        let hasSelection = !selectedURLs().isEmpty
        if cfg.favoriteDirs.isEmpty {
            let none = NSMenuItem(title: "（无收藏目录）", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for fav in cfg.favoriteDirs {
            let mi = NSMenuItem(title: fav.name, action: #selector(copyMoveTo(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = CopyMoveRequest(destPath: expand(fav.path), move: move)
            mi.isEnabled = hasSelection
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    private func makeFavoritesOpenItem(cfg: FinderSyncConfig) -> NSMenuItem {
        let item = NSMenuItem(title: "常用目录", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "")
        if cfg.favoriteDirs.isEmpty {
            let none = NSMenuItem(title: "（无收藏目录）", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for fav in cfg.favoriteDirs {
            let mi = NSMenuItem(title: fav.name, action: #selector(openFavorite(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = expand(fav.path)
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    private func makeCopyPathItem() -> NSMenuItem {
        let mi = NSMenuItem(title: "拷贝路径", action: #selector(copyPaths), keyEquivalent: "")
        mi.target = self
        mi.isEnabled = !selectedURLs().isEmpty
        return mi
    }

    private func makeAddFavoriteItem() -> NSMenuItem {
        let mi = NSMenuItem(title: "添加到常用目录", action: #selector(addFavorite), keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func makeHiddenItem(show: Bool) -> NSMenuItem {
        let mi = NSMenuItem(
            title: show ? "显示所有文件" : "隐藏所有文件",
            action: #selector(toggleHiddenFiles(_:)),
            keyEquivalent: ""
        )
        mi.target = self
        mi.representedObject = show
        return mi
    }

    private func makeTerminalItem() -> NSMenuItem {
        let mi = NSMenuItem(title: "进入终端", action: #selector(openTerminal), keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func makeOpenWithItem(cfg: FinderSyncConfig) -> NSMenuItem? {
        guard cfg.features.openWithEnabled, !cfg.openWithApps.isEmpty else { return nil }
        let item = NSMenuItem(title: "用…打开", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "")
        let hasSelection = !selectedURLs().isEmpty
        for app in cfg.openWithApps {
            let mi = NSMenuItem(title: app.name, action: #selector(openWithApp(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = app.bundleId
            mi.isEnabled = hasSelection
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    private func makeCopyNameItem() -> NSMenuItem {
        let mi = NSMenuItem(title: "拷贝文件名", action: #selector(copyNames), keyEquivalent: "")
        mi.target = self
        mi.isEnabled = !selectedURLs().isEmpty
        return mi
    }

    private func makeSendAliasItem() -> NSMenuItem {
        let mi = NSMenuItem(title: "发送到桌面（替身）", action: #selector(sendAliasToDesktop), keyEquivalent: "")
        mi.target = self
        mi.isEnabled = !selectedURLs().isEmpty
        return mi
    }

    private func makeCompressItem() -> NSMenuItem {
        let mi = NSMenuItem(title: "压缩为 zip", action: #selector(compressZip), keyEquivalent: "")
        mi.target = self
        mi.isEnabled = !selectedURLs().isEmpty
        return mi
    }

    private func makeExtractItem() -> NSMenuItem {
        let mi = NSMenuItem(title: "解压到当前文件夹", action: #selector(extractHere), keyEquivalent: "")
        mi.target = self
        let exts = ["zip", "tar", "gz", "tgz", "7z"]
        mi.isEnabled = selectedURLs().contains { exts.contains($0.pathExtension.lowercased()) }
        return mi
    }

    private func makePermanentDeleteItem() -> NSMenuItem {
        let mi = NSMenuItem(title: "彻底删除…", action: #selector(permanentDelete), keyEquivalent: "")
        mi.target = self
        mi.isEnabled = !selectedURLs().isEmpty
        return mi
    }

    // MARK: - 动作

    @objc private func createNewFile(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? NewFileRequest else { return }
        let dir = targetDir()
        let dest = uniqueURL(in: dir, baseName: req.fileName)
        var ok = false
        if let template = req.template,
           let resURL = Bundle.main.resourceURL?
               .appendingPathComponent("Templates")
               .appendingPathComponent(template),
           FileManager.default.fileExists(atPath: resURL.path) {
            ok = (try? FileManager.default.copyItem(at: resURL, to: dest)) != nil
        } else {
            ok = FileManager.default.createFile(atPath: dest.path, contents: nil)
        }
        if ok {
            // 选中新创建的文件，方便继续操作
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        }
    }

    @objc private func copyMoveTo(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? CopyMoveRequest else { return }
        let dest = URL(fileURLWithPath: req.destPath)
        guard FileManager.default.fileExists(atPath: dest.path) else { return }
        for src in selectedURLs() {
            let target = uniqueURL(in: dest, baseName: src.lastPathComponent)
            if req.move {
                _ = try? FileManager.default.moveItem(at: src, to: target)
            } else {
                _ = try? FileManager.default.copyItem(at: src, to: target)
            }
        }
    }

    @objc private func openFavorite(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func copyPaths() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let text = urls.map(\.path).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func addFavorite() {
        let dir = targetDir()
        let path = dir.path
        var cfg = FinderSyncConfig.load()
        guard !cfg.favoriteDirs.contains(where: { expand($0.path) == path }) else { return }
        cfg.favoriteDirs.append(FavoriteDir(name: dir.lastPathComponent, path: path))
        cfg.save()
    }

    @objc private func toggleHiddenFiles(_ sender: NSMenuItem) {
        let show = (sender.representedObject as? Bool) ?? false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", show ? "true" : "false"]
        try? p.run()
        p.waitUntilExit()

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["Finder"]
        try? kill.run()
        kill.waitUntilExit()
    }

    @objc private func openTerminal() {
        let dir = targetDir()
        let ws = NSWorkspace.shared
        if let terminal = ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            ws.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "Terminal", dir.path]
            try? p.run()
        }
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let bundleId = sender.representedObject as? String else { return }
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let ws = NSWorkspace.shared
        // 优先按 bundleId 定位；若未安装则当作绝对路径回退。
        let appURL: URL?
        if bundleId.hasPrefix("/"), FileManager.default.fileExists(atPath: bundleId) {
            appURL = URL(fileURLWithPath: bundleId)
        } else {
            appURL = ws.urlForApplication(withBundleIdentifier: bundleId)
        }
        guard let appURL else { return }
        ws.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func copyNames() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let text = urls.map { $0.lastPathComponent }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func sendAliasToDesktop() {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        guard FileManager.default.fileExists(atPath: desktop.path) else { return }
        for src in selectedURLs() {
            let dest = uniqueURL(in: desktop, baseName: src.lastPathComponent)
            createAlias(from: src, to: dest)
        }
    }

    private func createAlias(from source: URL, to aliasURL: URL) {
        guard let data = try? source.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        try? URL.writeBookmarkData(data, to: aliasURL)
    }

    @objc private func compressZip() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let dir = targetDir()
        let base = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "归档"
        let zipName = uniqueURL(in: dir, baseName: base + ".zip").lastPathComponent
        let dest = dir.appendingPathComponent(zipName)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-r", "-q", dest.path] + urls.map { $0.path }
        try? p.run()
        p.waitUntilExit()
    }

    @objc private func extractHere() {
        let dir = targetDir()
        for src in selectedURLs() where ["zip", "tar", "gz", "tgz", "7z"].contains(src.pathExtension.lowercased()) {
            if src.pathExtension.lowercased() == "7z", let sz = sevenZipURL() {
                let p = Process()
                p.executableURL = sz
                p.arguments = ["x", "-y", "-o\(dir.path)", src.path]
                try? p.run()
                p.waitUntilExit()
            } else {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", src.path, dir.path]
                try? p.run()
                p.waitUntilExit()
            }
        }
    }

    /// 若本机安装了 p7zip，返回其可执行文件 URL，否则 nil。
    private func sevenZipURL() -> URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["7z"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else { return nil }
        return URL(fileURLWithPath: out)
    }

    @MainActor @objc private func permanentDelete() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let count = urls.count
        let names = urls.map { $0.lastPathComponent }.joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = "彻底删除？"
        alert.informativeText = "将永久删除 \(count) 项，不可恢复：\n\(names)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let fm = FileManager.default
        for u in urls {
            _ = try? fm.removeItem(at: u)
        }
    }

    // MARK: - 工具

    private func uniqueURL(in dir: URL, baseName: String) -> URL {
        let ns = baseName as NSString
        let name = ns.deletingPathExtension
        let ext = ns.pathExtension
        var candidate = dir.appendingPathComponent(baseName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }
}
