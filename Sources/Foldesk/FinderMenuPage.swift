import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FoldeskShared

struct FinderMenuPage: View {
    @State private var config: FinderSyncConfig = .load()
    @State private var showingAddDir = false
    @State private var showingAddApp = false

    private let templateOptions: [(key: String, label: String)] = [
        ("xlsx", "Microsoft Excel 工作簿 (.xlsx)"),
        ("docx", "Microsoft Word 文档 (.docx)"),
        ("pptx", "Microsoft PowerPoint 演示文稿 (.pptx)"),
        ("txt", "文本文档 (.txt)"),
        ("md", "Markdown (.md)")
    ]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "右键服务", subtitle: "通过 macOS「服务」在访达右键中提供新建文件、复制路径等操作")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MenuSectionCard(title: "使用方式") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("1. 将 Foldesk 放到 /Applications 并打开一次。")
                            Text("2. 在访达中右键文件/文件夹（或空白处）→「服务」→ 选择 Foldesk 动作。")
                            Text("3. 可在 系统设置 → 键盘 → 键盘快捷键 → 服务 中把常用项提到顶层。")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    MenuSectionCard(title: "可用服务") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• 新建 Excel / Word / PPT / 文本 / Markdown（落于当前访达目录）")
                            Text("• 复制路径 / 复制文件名（需选中文件）")
                            Text("• 压缩为 zip / 解压到此处")
                            Text("• 彻底删除（弹窗二次确认）")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    MenuSectionCard(title: "新建文件模板") {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(templateOptions, id: \.key) { opt in
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.foldeskBlue)
                                    Text(opt.label).lineLimit(1)
                                }
                            }
                        }
                        Text("Excel / Word / PPT 使用内置空白模板，无需安装 Office 即可生成可正常打开的文件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    MenuSectionCard(title: "常用目录（规划中）") {
                        Text("将来用于「复制到 / 移动到」服务时会列出以下文件夹。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(config.favoriteDirs) { fav in
                                HStack(spacing: 8) {
                                    Image(systemName: "folder").foregroundStyle(Color.foldeskBlue)
                                    Text(fav.name).lineLimit(1)
                                    Spacer()
                                    Text(fav.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Button { removeFav(fav) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Button { showingAddDir = true } label: {
                            Label("添加目录", systemImage: "plus")
                        }
                        .controlSize(.small)
                    }

                    MenuSectionCard(title: "用指定 App 打开（规划中）") {
                        Text("将来「用…打开」服务会列出以下 App。当前服务版本暂未包含此动作。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(config.openWithApps) { app in
                                HStack(spacing: 8) {
                                    Image(systemName: "app")
                                    Text(app.name).lineLimit(1)
                                    Spacer()
                                    Button { removeApp(app) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Button { showingAddApp = true } label: {
                            Label("添加 App", systemImage: "plus")
                        }
                        .controlSize(.small)
                    }
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $showingAddDir) { addDirSheet }
        .sheet(isPresented: $showingAddApp) { addAppSheet }
    }

    private var addDirSheet: some View {
        DirPickerSheet(
            onAdd: { url in
                let path = url.path
                guard !config.favoriteDirs.contains(where: { $0.path == path }) else { return }
                config.favoriteDirs.append(FavoriteDir(name: url.lastPathComponent, path: path))
                config.save()
            },
            onDismiss: { showingAddDir = false }
        )
    }

    private var addAppSheet: some View {
        AppPickerSheet(
            onAdd: { url in
                let bundleId = Bundle(url: url)?.bundleIdentifier ?? url.path
                let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
                guard !config.openWithApps.contains(where: { $0.bundleId == bundleId }) else { return }
                config.openWithApps.append(OpenWithApp(name: name, bundleId: bundleId))
                config.save()
            },
            onDismiss: { showingAddApp = false }
        )
    }

    private func removeFav(_ fav: FavoriteDir) {
        config.favoriteDirs.removeAll { $0.id == fav.id }
        config.save()
    }

    private func removeApp(_ app: OpenWithApp) {
        config.openWithApps.removeAll { $0.id == app.id }
        config.save()
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

private struct DirPickerSheet: View {
    let onAdd: (URL) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("选择常用目录").font(.headline)
            Button("选取文件夹…") {
                let panel = NSOpenPanel()
                panel.title = "选择常用目录"
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    onAdd(url)
                }
                onDismiss()
            }
            .controlSize(.large)
            Button("取消", role: .cancel) { onDismiss() }
        }
        .padding(24)
        .frame(width: 320)
    }
}

private struct AppPickerSheet: View {
    let onAdd: (URL) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("选择 App").font(.headline)
            Button("选取 .app…") {
                let panel = NSOpenPanel()
                panel.title = "选择 App"
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [UTType.application]
                if panel.runModal() == .OK, let url = panel.url {
                    onAdd(url)
                }
                onDismiss()
            }
            .controlSize(.large)
            Button("取消", role: .cancel) { onDismiss() }
        }
        .padding(24)
        .frame(width: 320)
    }
}
