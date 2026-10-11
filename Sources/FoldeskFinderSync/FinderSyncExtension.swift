import AppKit
import Darwin
import FinderSync
import OSLog
#if canImport(FoldeskShared)
import FoldeskShared
#endif

private let finderLog = Logger(subsystem: "com.foldesk.mac.findersync", category: "new-file")

/// Finder 原生右键入口。扩展只响应用户明确点击的动作，不会因“新建文件”
/// 唤醒 Word、WPS、Finder 或 Foldesk 主窗口。
class FinderSyncExtension: FIFinderSync, @unchecked Sendable {
    private let fileManager = FileManager.default
    private var pendingDirectory: URL?
    private var pendingSelectedURLs: [URL] = []

    override init() {
        super.init()
        // Finder Sync 不会可靠地接受“/”作为监听根目录。直接监听实际
        // 用户主目录，确保桌面、文稿、下载和用户自建目录都能显示菜单。
        FIFinderSyncController.`default`().directoryURLs = Set([
            Self.realHomeDirectoryURL,
            URL(fileURLWithPath: "/Volumes", isDirectory: true)
        ])
        NSLog(
            "FoldeskFinderSync: 扩展已加载 createDocx=%d",
            responds(to: #selector(createDocx(_:))) ? 1 : 0
        )
    }

    /// 与 `FinderSyncConfig.realHomeDirectoryPath` 保持一致：沙盒里的
    /// `FileManager.homeDirectoryForCurrentUser` 会指向扩展自己的容器，
    /// 用它做监听根目录会让桌面、文稿、下载全部收不到右键菜单。
    private static var realHomeDirectoryURL: URL {
        URL(fileURLWithPath: FinderSyncConfig.realHomeDirectoryPath, isDirectory: true)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let config = FinderSyncConfig.load()
        guard config.enabled else { return nil }

        let selected = selectedURLs()
        let directory = destinationDirectory(for: menuKind, selected: selected)
        pendingSelectedURLs = selected
        pendingDirectory = directory
        let menu = NSMenu(title: "")

        if directory != nil {
            // Finder 右键第一层直接显示“新建文件”，不再套 Foldesk 子菜单。
            menu.addItem(newFileMenu(config: config))
        }

        if !selected.isEmpty {
            if directory != nil { menu.addItem(.separator()) }
            menu.addItem(copyTextItem(title: "复制完整路径", urls: selected, namesOnly: false))
            if config.features.copyName {
                menu.addItem(copyTextItem(title: "复制文件名", urls: selected, namesOnly: true))
            }
            if config.features.compress {
                menu.addItem(actionItem(title: "压缩为 ZIP", action: #selector(compress(_:))))
            }
            if config.features.extract, selected.contains(where: { $0.pathExtension.lowercased() == "zip" }) {
                menu.addItem(actionItem(title: "解压到当前文件夹", action: #selector(extract(_:))))
            }
            menu.addItem(copyMoveMenu(config: config, selected: selected, move: false))
            menu.addItem(copyMoveMenu(config: config, selected: selected, move: true))
            if config.features.openWithEnabled, !config.openWithApps.isEmpty {
                menu.addItem(openWithMenu(config: config, selected: selected))
            }
            if config.features.sendAliasToDesktop {
                menu.addItem(actionItem(title: "发送替身到桌面", action: #selector(sendAliases(_:))))
            }
            if config.features.permanentDelete {
                menu.addItem(actionItem(title: "彻底删除…", action: #selector(permanentDelete(_:))))
            }
        }

        if directory != nil {
            menu.addItem(.separator())
            menu.addItem(actionItem(title: "在终端中打开", action: #selector(openTerminal(_:))))
        }
        if !config.favoriteDirs.isEmpty {
            menu.addItem(openFavoritesMenu(config: config))
        }

        return menu.items.isEmpty ? nil : menu
    }

    // MARK: - Menu construction

    private func newFileMenu(config: FinderSyncConfig) -> NSMenuItem {
        // 刻意带上 Foldesk 标识：WPS 等办公软件会往同一个右键菜单里插自己的
        // “新建”项（见 WPSFinderMenu.appex），不带标识时用户分不清点了谁。
        let title = "新建文件（Foldesk）"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for kind in FoldeskNewFileKind.allCases
        where config.newFileTemplates[kind.rawValue] ?? true {
            submenu.addItem(actionItem(
                title: kind.menuTitle,
                action: newFileSelector(for: kind)
            ))
        }
        if submenu.items.isEmpty {
            let disabled = NSMenuItem(title: "没有启用的文件类型", action: nil, keyEquivalent: "")
            disabled.isEnabled = false
            submenu.addItem(disabled)
        }
        item.submenu = submenu
        return item
    }

    private func copyTextItem(title: String, urls: [URL], namesOnly: Bool) -> NSMenuItem {
        actionItem(
            title: title,
            action: namesOnly ? #selector(copyNames(_:)) : #selector(copyPaths(_:))
        )
    }

    private func copyMoveMenu(config: FinderSyncConfig, selected: [URL], move: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: move ? "移动到常用目录" : "复制到常用目录", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        for (index, favorite) in config.favoriteDirs.prefix(FinderSyncConfig.serviceSlotLimit).enumerated() {
            let destination = URL(fileURLWithPath: expand(favorite.path), isDirectory: true)
            let child = actionItem(
                title: favorite.name,
                action: copyMoveSelector(index: index, move: move)
            )
            child.isEnabled = directoryIsWritable(destination)
            submenu.addItem(child)
        }
        if submenu.items.isEmpty {
            let disabled = NSMenuItem(title: "未配置常用目录", action: nil, keyEquivalent: "")
            disabled.isEnabled = false
            submenu.addItem(disabled)
        }
        item.submenu = submenu
        return item
    }

    private func openWithMenu(config: FinderSyncConfig, selected: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: "用指定 App 打开", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        for (index, application) in config.openWithApps.prefix(FinderSyncConfig.serviceSlotLimit).enumerated() {
            let child = actionItem(
                title: application.name,
                action: openWithSelector(index: index)
            )
            child.isEnabled = applicationURL(application.bundleId) != nil
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }

    private func openFavoritesMenu(config: FinderSyncConfig) -> NSMenuItem {
        let item = NSMenuItem(title: "打开常用目录", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        for (index, favorite) in config.favoriteDirs.prefix(FinderSyncConfig.serviceSlotLimit).enumerated() {
            let url = URL(fileURLWithPath: expand(favorite.path), isDirectory: true)
            let child = actionItem(title: favorite.name, action: openFavoriteSelector(index: index))
            child.isEnabled = fileManager.fileExists(atPath: url.path)
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        // 与 Xcode Finder Sync 模板保持一致：target 留空，由 Finder 把
        // selector 转交给扩展 principal object。
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    /// 所有菜单动作的统一入口。
    ///
    /// Finder 是在自己的 XPC 队列上调用菜单 selector 的，而 Swift 6 会把带
    /// `@IBAction` 的方法隐式视为 `@MainActor`。一旦在入口方法体里直接碰 AppKit，
    /// 就会命中 `dispatch_assert_queue` 断言、整个扩展进程被系统终止 —— 表现为
    /// 点了菜单毫无反应，或菜单随之消失。所以入口一律 `nonisolated`，只负责把
    /// 工作交给主线程，真正的实现放在不带 `@IBAction` 的私有方法里。
    private nonisolated func onMain(
        _ action: @escaping @MainActor @Sendable (FinderSyncExtension) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            action(self)
        }
    }

    // MARK: - New file

    // macOS 26 会在 Finder 的 XPC 队列上调用菜单 selector；Swift 6 则会
    // 把 AppKit 子类方法隐式视为 MainActor。入口必须 nonisolated，再显式
    // 跳回主线程，否则一点菜单扩展就会被 dispatch_assert_queue 终止。
    @IBAction nonisolated func createDocx(_ sender: AnyObject?) { createNewFileOnMain(.docx) }
    @IBAction nonisolated func createXlsx(_ sender: AnyObject?) { createNewFileOnMain(.xlsx) }
    @IBAction nonisolated func createPptx(_ sender: AnyObject?) { createNewFileOnMain(.pptx) }
    @IBAction nonisolated func createRtf(_ sender: AnyObject?) { createNewFileOnMain(.rtf) }
    @IBAction nonisolated func createTxt(_ sender: AnyObject?) { createNewFileOnMain(.txt) }
    @IBAction nonisolated func createMarkdown(_ sender: AnyObject?) { createNewFileOnMain(.markdown) }
    @IBAction nonisolated func createCsv(_ sender: AnyObject?) { createNewFileOnMain(.csv) }
    @IBAction nonisolated func createJson(_ sender: AnyObject?) { createNewFileOnMain(.json) }
    @IBAction nonisolated func createHtml(_ sender: AnyObject?) { createNewFileOnMain(.html) }
    @IBAction nonisolated func createXml(_ sender: AnyObject?) { createNewFileOnMain(.xml) }
    @IBAction nonisolated func createEmpty(_ sender: AnyObject?) { createNewFileOnMain(.empty) }

    private nonisolated func createNewFileOnMain(_ kind: FoldeskNewFileKind) {
        finderLog.notice("action received type=\(kind.rawValue, privacy: .public)")
        Task { @MainActor [weak self] in
            finderLog.notice("main task type=\(kind.rawValue, privacy: .public)")
            self?.createNewFile(kind)
        }
    }

    private func createNewFile(_ kind: FoldeskNewFileKind) {
        // Finder 在动作回调时可能把当前窗口目录同时放进
        // selectedItemURLs，再算会错误地退回父目录。菜单展开时的目标
        // 目录是本次操作唯一稳定的上下文。
        let directory = pendingDirectory ?? currentTargetDirectory()
        guard let directory else {
            // 以前这里是静默 return：用户点了菜单什么都不会发生，也不会知道为什么。
            finderLog.error("missing Finder target directory type=\(kind.rawValue, privacy: .public)")
            showError(
                title: "没有确定要新建到哪个文件夹",
                message: "Finder 没有把当前文件夹传给 Foldesk。请回到目标文件夹的空白处重新右键，再选一次「新建文件」。"
            )
            return
        }
        guard let resources = Bundle(for: FinderSyncExtension.self).resourceURL else {
            finderLog.error("missing extension resources type=\(kind.rawValue, privacy: .public)")
            showError(
                title: "扩展资源缺失",
                message: "找不到扩展包内的模板目录，Office 文档无法创建。请重新运行 scripts/install-local.sh 安装完整版本。"
            )
            return
        }
        let didAccess = directory.startAccessingSecurityScopedResource()
        defer {
            if didAccess { directory.stopAccessingSecurityScopedResource() }
        }
        do {
            let created = try FoldeskNewFileCreator.create(
                kind,
                in: directory,
                templatesDirectory: resources.appendingPathComponent("Templates", isDirectory: true)
            )
            // 记下真实落盘位置：排查“文件到底建到哪去了”时这是唯一可靠依据。
            finderLog.notice("created type=\(kind.rawValue, privacy: .public) at=\(created.path, privacy: .public)")
        } catch {
            finderLog.error("failed type=\(kind.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            showError(title: "新建文件失败", message: error.localizedDescription)
        }
    }

    // MARK: - Clipboard and file operations

    @IBAction nonisolated func copyPaths(_ sender: AnyObject?) { onMain { $0.performCopyPaths() } }
    @IBAction nonisolated func copyNames(_ sender: AnyObject?) { onMain { $0.performCopyNames() } }

    private func performCopyPaths() {
        let urls = actionSelectedURLs()
        guard !urls.isEmpty else { return }
        writePasteboard(urls.map(\.path).joined(separator: "\n"))
    }

    private func performCopyNames() {
        let urls = actionSelectedURLs()
        guard !urls.isEmpty else { return }
        writePasteboard(urls.map(\.lastPathComponent).joined(separator: "\n"))
    }

    @IBAction nonisolated func copyToFavorite0(_ sender: AnyObject?) { onMain { $0.copyOrMove(favoriteIndex: 0, move: false) } }
    @IBAction nonisolated func copyToFavorite1(_ sender: AnyObject?) { onMain { $0.copyOrMove(favoriteIndex: 1, move: false) } }
    @IBAction nonisolated func copyToFavorite2(_ sender: AnyObject?) { onMain { $0.copyOrMove(favoriteIndex: 2, move: false) } }
    @IBAction nonisolated func moveToFavorite0(_ sender: AnyObject?) { onMain { $0.copyOrMove(favoriteIndex: 0, move: true) } }
    @IBAction nonisolated func moveToFavorite1(_ sender: AnyObject?) { onMain { $0.copyOrMove(favoriteIndex: 1, move: true) } }
    @IBAction nonisolated func moveToFavorite2(_ sender: AnyObject?) { onMain { $0.copyOrMove(favoriteIndex: 2, move: true) } }

    private func copyOrMove(favoriteIndex: Int, move: Bool) {
        let config = FinderSyncConfig.load()
        let sources = actionSelectedURLs()
        guard config.favoriteDirs.indices.contains(favoriteIndex), !sources.isEmpty else { return }
        let requestDestination = URL(
            fileURLWithPath: expand(config.favoriteDirs[favoriteIndex].path),
            isDirectory: true
        )
        guard directoryIsWritable(requestDestination) else { return }
        for source in sources {
            let destination = uniqueURL(in: requestDestination, fileName: source.lastPathComponent)
            do {
                if move {
                    try fileManager.moveItem(at: source, to: destination)
                } else {
                    try fileManager.copyItem(at: source, to: destination)
                }
            } catch {
                showError(title: move ? "移动失败" : "复制失败", message: "\(source.lastPathComponent)：\(error.localizedDescription)")
                return
            }
        }
    }

    @IBAction nonisolated func compress(_ sender: AnyObject?) { onMain { $0.performCompress() } }

    private func performCompress() {
        let urls = actionSelectedURLs()
        guard let first = urls.first else { return }
        let parent = first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Foldesk归档"
        let destination = uniqueURL(in: parent, fileName: base + ".zip")
        run(
            executable: "/usr/bin/zip",
            arguments: ["-q", "-r", destination.path, "--"] + urls.map(\.path),
            failureTitle: "压缩失败"
        )
    }

    @IBAction nonisolated func extract(_ sender: AnyObject?) { onMain { $0.performExtract() } }

    private func performExtract() {
        let urls = actionSelectedURLs()
        guard !urls.isEmpty else { return }
        for source in urls where source.pathExtension.lowercased() == "zip" {
            let destination = uniqueDirectory(
                in: source.deletingLastPathComponent(),
                baseName: source.deletingPathExtension().lastPathComponent
            )
            do {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                showError(title: "解压失败", message: error.localizedDescription)
                return
            }
            if !run(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", source.path, destination.path],
                failureTitle: "解压失败"
            ) {
                try? fileManager.removeItem(at: destination)
                return
            }
        }
    }

    @IBAction nonisolated func sendAliases(_ sender: AnyObject?) { onMain { $0.performSendAliases() } }

    private func performSendAliases() {
        let urls = actionSelectedURLs()
        guard !urls.isEmpty else { return }
        // 沙盒里 `homeDirectoryForCurrentUser` 是容器数据目录，直接把替身写进去
        // 用户永远看不到。桌面必须由真实 home 推导。
        let desktop = URL(fileURLWithPath: FinderSyncConfig.realHomeDirectoryPath, isDirectory: true)
            .appendingPathComponent("Desktop", isDirectory: true)
        for source in urls {
            let destination = uniqueURL(in: desktop, fileName: source.lastPathComponent)
            do {
                let data = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: destination)
            } catch {
                showError(title: "创建替身失败", message: error.localizedDescription)
                return
            }
        }
    }

    @IBAction nonisolated func permanentDelete(_ sender: AnyObject?) { onMain { $0.performPermanentDelete() } }

    private func performPermanentDelete() {
        let urls = actionSelectedURLs()
        guard !urls.isEmpty else { return }
        let protected = urls.filter(isProtectedDeletionTarget)
        guard protected.isEmpty else {
            showError(title: "不能删除", message: "所选项目包含受保护的系统目录。")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "彻底删除 \(urls.count) 项？"
        alert.informativeText = "文件不会进入废纸篓，此操作无法撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for url in urls {
            do { try fileManager.removeItem(at: url) }
            catch {
                showError(title: "删除失败", message: "\(url.lastPathComponent)：\(error.localizedDescription)")
                return
            }
        }
    }

    // MARK: - Explicit open actions

    @IBAction nonisolated func openWithApplication0(_ sender: AnyObject?) { onMain { $0.openWithApplication(index: 0) } }
    @IBAction nonisolated func openWithApplication1(_ sender: AnyObject?) { onMain { $0.openWithApplication(index: 1) } }
    @IBAction nonisolated func openWithApplication2(_ sender: AnyObject?) { onMain { $0.openWithApplication(index: 2) } }

    private func openWithApplication(index: Int) {
        let config = FinderSyncConfig.load()
        let urls = actionSelectedURLs()
        guard config.openWithApps.indices.contains(index), !urls.isEmpty,
              let application = applicationURL(config.openWithApps[index].bundleId) else { return }
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @IBAction nonisolated func openFavorite0(_ sender: AnyObject?) { onMain { $0.openFavorite(index: 0) } }
    @IBAction nonisolated func openFavorite1(_ sender: AnyObject?) { onMain { $0.openFavorite(index: 1) } }
    @IBAction nonisolated func openFavorite2(_ sender: AnyObject?) { onMain { $0.openFavorite(index: 2) } }

    private func openFavorite(index: Int) {
        let config = FinderSyncConfig.load()
        guard config.favoriteDirs.indices.contains(index) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: expand(config.favoriteDirs[index].path), isDirectory: true))
    }

    @IBAction nonisolated func openTerminal(_ sender: AnyObject?) { onMain { $0.performOpenTerminal() } }

    private func performOpenTerminal() {
        guard let directory = currentTargetDirectory(),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - Finder context and helpers

    /// 菜单构建阶段使用：严格反映 Finder 此刻的选中项，不回退。
    /// 这里若回退到上一轮快照，会拿旧选中项构造出错误菜单。
    private func selectedURLs() -> [URL] {
        FIFinderSyncController.`default`().selectedItemURLs() ?? []
    }

    /// 动作执行阶段使用。Finder 在动作回调里可能拿不到选中项（macOS 26 上会
    /// 返回空数组而不是 nil），此时必须回退到菜单展开时记录的快照，否则
    /// 「复制路径 / 压缩 / 彻底删除」等会静默失败 —— 用户看到的是点了没反应。
    private func actionSelectedURLs() -> [URL] {
        let live = FIFinderSyncController.`default`().selectedItemURLs() ?? []
        return live.isEmpty ? pendingSelectedURLs : live
    }

    private func currentTargetDirectory() -> URL? {
        let controller = FIFinderSyncController.`default`()
        let selected = actionSelectedURLs()
        guard let targeted = controller.targetedURL() ?? selected.first else { return pendingDirectory }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: targeted.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // 选中了一个文件夹时，右键动作仍落在它的父目录；在空白处右键时
            // selected 为空，此时 targeted 正是当前 Finder 目录。
            return selected.contains(targeted) ? targeted.deletingLastPathComponent() : targeted
        }
        return targeted.deletingLastPathComponent()
    }

    private func newFileSelector(for kind: FoldeskNewFileKind) -> Selector {
        switch kind {
        case .docx: #selector(createDocx(_:))
        case .xlsx: #selector(createXlsx(_:))
        case .pptx: #selector(createPptx(_:))
        case .rtf: #selector(createRtf(_:))
        case .txt: #selector(createTxt(_:))
        case .markdown: #selector(createMarkdown(_:))
        case .csv: #selector(createCsv(_:))
        case .json: #selector(createJson(_:))
        case .html: #selector(createHtml(_:))
        case .xml: #selector(createXml(_:))
        case .empty: #selector(createEmpty(_:))
        }
    }

    private func copyMoveSelector(index: Int, move: Bool) -> Selector {
        if move {
            return [#selector(moveToFavorite0(_:)), #selector(moveToFavorite1(_:)), #selector(moveToFavorite2(_:))][index]
        }
        return [#selector(copyToFavorite0(_:)), #selector(copyToFavorite1(_:)), #selector(copyToFavorite2(_:))][index]
    }

    private func openWithSelector(index: Int) -> Selector {
        [#selector(openWithApplication0(_:)), #selector(openWithApplication1(_:)), #selector(openWithApplication2(_:))][index]
    }

    private func openFavoriteSelector(index: Int) -> Selector {
        [#selector(openFavorite0(_:)), #selector(openFavorite1(_:)), #selector(openFavorite2(_:))][index]
    }

    private func destinationDirectory(for menuKind: FIMenuKind, selected: [URL]) -> URL? {
        let controller = FIFinderSyncController.`default`()
        if menuKind == .contextualMenuForItems, let first = selected.first {
            // 在文件或文件夹图标上右键时，与 Windows 一样在其所在目录创建，
            // 而不是误把新文件塞进被选中的文件夹内部。
            return first.deletingLastPathComponent()
        }
        guard let targeted = controller.targetedURL() ?? selected.first else { return nil }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: targeted.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return targeted
        }
        return targeted.deletingLastPathComponent()
    }

    private func applicationURL(_ identifierOrPath: String) -> URL? {
        let value = identifierOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/") {
            return fileManager.fileExists(atPath: value) ? URL(fileURLWithPath: value) : nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
    }

    private func directoryIsWritable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isWritableFile(atPath: url.path)
    }

    private func uniqueURL(in directory: URL, fileName: String) -> URL {
        let value = fileName as NSString
        let base = value.deletingPathExtension
        let ext = value.pathExtension
        for index in 1...10_000 {
            let suffix = index == 1 ? "" : " \(index)"
            let name = ext.isEmpty ? base + suffix : base + suffix + "." + ext
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }

    private func uniqueDirectory(in parent: URL, baseName: String) -> URL {
        for index in 1...10_000 {
            let suffix = index == 1 ? "" : " \(index)"
            let candidate = parent.appendingPathComponent(baseName + suffix, isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func writePasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @discardableResult
    private func run(executable: String, arguments: [String], failureTitle: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                showError(title: failureTitle, message: "命令执行失败（状态码 \(process.terminationStatus)）。")
                return false
            }
            return true
        } catch {
            showError(title: failureTitle, message: error.localizedDescription)
            return false
        }
    }

    private func isProtectedDeletionTarget(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        // 沙盒里的 NSHomeDirectory() 指向容器，会让家目录保护形同虚设。
        return Set([
            "/",
            FinderSyncConfig.realHomeDirectoryPath,
            "/Applications", "/Library", "/System", "/Users", "/private"
        ]).contains(path)
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
