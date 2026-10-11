import SwiftUI
import AppKit
import FinderSync
import UniformTypeIdentifiers
import FoldeskShared

struct FinderMenuPage: View {
    @State private var config = FinderSyncConfig.default
    @State private var loadedConfig: FinderSyncConfig?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveMessage = "配置已载入"
    @State private var saveFailed = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "超级右键", subtitle: "通过 Finder 原生扩展在当前文件夹直接新建文件，并提供常用文件操作")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MenuSectionCard(title: "启用 Finder 扩展") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("1. 将 Foldesk 放到 /Applications 并打开一次。")
                            Text("2. 点下方按钮，在系统的 Finder 扩展列表中启用“Foldesk 右键菜单”。")
                            Text("3. 在 Finder 当前文件夹空白处右键 → 新建文件。")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Button {
                            FIFinderSyncController.showExtensionManagementInterface()
                        } label: {
                            Label("打开 Finder 扩展设置", systemImage: "puzzlepiece.extension")
                        }
                        .buttonStyle(.borderedProminent)
                        Text("旧版“右键 → 服务”入口仍保留作为兼容备用；Finder 扩展会在右键第一层直接显示“新建文件”。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    MenuSectionCard(title: "可用服务") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• 新建 Word / Excel / PowerPoint / RTF / 文本 / Markdown / CSV / JSON / HTML / XML / 空文件")
                            Text("• 新建操作只生成文件，不会打开 Word、WPS 或其他软件")
                            Text("• 复制路径 / 复制文件名（需选中文件）")
                            Text("• 压缩为 zip / 解压到此处")
                            Text("• 彻底删除（弹窗二次确认）")
                            Text("• 复制/移动到常用目录、用指定 App 打开、发送替身到桌面")
                            Text("• 在终端中打开当前目录、快速打开常用目录")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    MenuSectionCard(title: "内置的新建文件类型") {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(FoldeskNewFileKind.allCases, id: \.rawValue) { kind in
                                Toggle(kind.menuTitle, isOn: templateBinding(for: kind))
                                    .toggleStyle(.switch)
                            }
                        }
                        Text("Word / Excel / PowerPoint 使用真实 OOXML 空白模板；Microsoft Office 与 WPS 都能打开同一份 .docx / .xlsx / .pptx 文件，无需分别创建两套类型。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    MenuSectionCard(title: "常用目录（对应「复制到 / 移动到常用目录 1·2·3」）") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($config.favoriteDirs) { $dir in
                                HStack(spacing: 8) {
                                    Text(slotLabel(config.favoriteDirs.firstIndex(where: { $0.id == dir.id }) ?? 0))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48, alignment: .leading)
                                    TextField("名称", text: $dir.name)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 120)
                                    TextField("路径（支持 ~）", text: $dir.path)
                                        .textFieldStyle(.roundedBorder)
                                    Image(systemName: directoryIsValid(dir.path) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(directoryIsValid(dir.path) ? .green : .orange)
                                        .help(directoryIsValid(dir.path) ? "目录可用" : "目录不存在、不是文件夹或不可写")
                                    Button {
                                        moveFavorite(dir.id, offset: -1)
                                    } label: { Image(systemName: "chevron.up") }
                                        .buttonStyle(.borderless)
                                        .disabled(config.favoriteDirs.first?.id == dir.id)
                                        .help("上移槽位")
                                    Button {
                                        moveFavorite(dir.id, offset: 1)
                                    } label: { Image(systemName: "chevron.down") }
                                        .buttonStyle(.borderless)
                                        .disabled(config.favoriteDirs.last?.id == dir.id)
                                        .help("下移槽位")
                                    Button(role: .destructive) {
                                        config.favoriteDirs.removeAll { $0.id == dir.id }
                                    } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                }
                            }
                            Button {
                                pickDirectory()
                            } label: {
                                Label("添加目录", systemImage: "plus")
                            }
                            .controlSize(.small)
                            .disabled(config.favoriteDirs.count >= FinderSyncConfig.serviceSlotLimit)
                        }
                        Text("前三项对应右键菜单的「常用目录 1/2/3」，可用箭头调整。旧版多余项保留为候补，上移到前三项即可使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    MenuSectionCard(title: "用指定 App 打开（对应「用指定 App 打开 1·2·3」）") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($config.openWithApps) { $app in
                                HStack(spacing: 8) {
                                    Text(slotLabel(config.openWithApps.firstIndex(where: { $0.id == app.id }) ?? 0))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48, alignment: .leading)
                                    TextField("名称", text: $app.name)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 120)
                                    TextField("Bundle Identifier", text: $app.bundleId)
                                        .textFieldStyle(.roundedBorder)
                                    Image(systemName: applicationIsValid(app.bundleId) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(applicationIsValid(app.bundleId) ? .green : .orange)
                                        .help(applicationIsValid(app.bundleId) ? "App 可用" : "找不到对应 App")
                                    Button {
                                        moveApplication(app.id, offset: -1)
                                    } label: { Image(systemName: "chevron.up") }
                                        .buttonStyle(.borderless)
                                        .disabled(config.openWithApps.first?.id == app.id)
                                        .help("上移槽位")
                                    Button {
                                        moveApplication(app.id, offset: 1)
                                    } label: { Image(systemName: "chevron.down") }
                                        .buttonStyle(.borderless)
                                        .disabled(config.openWithApps.last?.id == app.id)
                                        .help("下移槽位")
                                    Button(role: .destructive) {
                                        config.openWithApps.removeAll { $0.id == app.id }
                                    } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                }
                            }
                            Button {
                                pickApp()
                            } label: {
                                Label("添加 App", systemImage: "plus")
                            }
                            .controlSize(.small)
                            .disabled(config.openWithApps.count >= FinderSyncConfig.serviceSlotLimit)
                        }
                        Text("前三项对应菜单槽位，旧版多余项保留为候补。点「添加 App」会自动读取 Bundle ID；配置无效时会明确提示，不会改用其他程序。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: saveFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        Text(saveMessage)
                    }
                    .font(.caption)
                    .foregroundStyle(saveFailed ? Color.orange : Color.secondary)
                }
                .padding(20)
                .disabled(loadedConfig == nil)
            }
            if loadedConfig == nil {
                Button("重新读取配置") { loadConfiguration() }
                    .padding(.bottom, 12)
            }
        }
        .onAppear { loadConfiguration() }
        .onChange(of: config) { _, _ in scheduleSave() }
        .onDisappear {
            saveTask?.cancel()
            guard let loadedConfig, config != loadedConfig else { return }
            do {
                try config.save()
            } catch {
                NSLog("Foldesk: 保存右键服务配置失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 模板选项

    private func templateBinding(for kind: FoldeskNewFileKind) -> Binding<Bool> {
        Binding(
            get: { config.newFileTemplates[kind.rawValue] ?? true },
            set: { config.newFileTemplates[kind.rawValue] = $0 }
        )
    }

    // MARK: - 文件选择面板

    private func pickDirectory() {
        guard config.favoriteDirs.count < FinderSyncConfig.serviceSlotLimit else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择常用目录"
        if panel.runModal() == .OK, let url = panel.url {
            config.favoriteDirs.append(FavoriteDir(name: url.lastPathComponent, path: url.path))
        }
    }

    private func pickApp() {
        guard config.openWithApps.count < FinderSyncConfig.serviceSlotLimit else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.title = "选择 App"
        if panel.runModal() == .OK, let url = panel.url {
            guard let bundleId = Bundle(url: url)?.bundleIdentifier, !bundleId.isEmpty else {
                saveFailed = true
                saveMessage = "所选 App 没有有效的 Bundle Identifier"
                return
            }
            config.openWithApps.append(OpenWithApp(name: url.deletingPathExtension().lastPathComponent, bundleId: bundleId))
        }
    }

    private func scheduleSave() {
        guard let loadedConfig, config != loadedConfig else { return }
        saveTask?.cancel()
        saveMessage = "正在保存…"
        saveFailed = false
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                try config.save()
                self.loadedConfig = config
                saveMessage = "配置已保存"
            } catch {
                saveFailed = true
                saveMessage = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    private func loadConfiguration() {
        do {
            let loaded = try FinderSyncConfig.loadForServices()
            loadedConfig = loaded
            config = loaded
            saveFailed = false
            saveMessage = "配置已载入"
        } catch {
            loadedConfig = nil
            saveFailed = true
            saveMessage = "读取失败，原配置未被覆盖：\(error.localizedDescription)"
        }
    }

    private func slotLabel(_ index: Int) -> String {
        index < FinderSyncConfig.serviceSlotLimit ? "槽位 \(index + 1)" : "候补"
    }

    private func moveFavorite(_ id: UUID, offset: Int) {
        guard let source = config.favoriteDirs.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard config.favoriteDirs.indices.contains(destination) else { return }
        config.favoriteDirs.swapAt(source, destination)
    }

    private func moveApplication(_ id: UUID, offset: Int) {
        guard let source = config.openWithApps.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard config.openWithApps.indices.contains(destination) else { return }
        config.openWithApps.swapAt(source, destination)
    }

    private func directoryIsValid(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: expanded)
    }

    private func applicationIsValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: trimmed)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) != nil
    }
}

private struct MenuSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
