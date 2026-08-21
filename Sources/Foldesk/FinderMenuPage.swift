import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FoldeskShared

struct FinderMenuPage: View {
    @State private var config = FinderSyncConfig.load()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "右键服务", subtitle: "通过 macOS「服务」在访达右键中提供新建文件、复制路径、常用目录、指定 App 打开等操作")

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
                        Text("这些服务只在访达中出现，其他应用的右键菜单不会显示。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    MenuSectionCard(title: "可用服务") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• 新建 Excel / Word / PPT / 文本 / Markdown（落于当前访达目录）")
                            Text("• 复制路径 / 复制文件名（需选中文件）")
                            Text("• 压缩为 zip / 解压到此处")
                            Text("• 彻底删除（弹窗二次确认）")
                            Text("• 复制到常用目录 1 / 2 / 3（需选中文件，目标见下方配置）")
                            Text("• 移动到常用目录 1 / 2 / 3（需选中文件，目标见下方配置）")
                            Text("• 用指定 App 打开 1 / 2 / 3（需选中文件，App 见下方配置）")
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
                        Text("Excel / Word / PPT 使用内置空白模板，无需安装 Office 即可生成可正常打开的 Microsoft Office 文档。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    MenuSectionCard(title: "常用目录（对应「复制到 / 移动到常用目录 1·2·3」）") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($config.favoriteDirs) { $dir in
                                HStack(spacing: 8) {
                                    TextField("名称", text: $dir.name)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 120)
                                    TextField("路径（支持 ~）", text: $dir.path)
                                        .textFieldStyle(.roundedBorder)
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
                        }
                        Text("右键菜单里显示的是固定槽位名「常用目录 1/2/3」，分别指向这里的前 3 项（不足 3 项时对应槽位不生效）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    MenuSectionCard(title: "用指定 App 打开（对应「用指定 App 打开 1·2·3」）") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($config.openWithApps) { $app in
                                HStack(spacing: 8) {
                                    TextField("名称", text: $app.name)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 120)
                                    TextField("Bundle Identifier", text: $app.bundleId)
                                        .textFieldStyle(.roundedBorder)
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
                        }
                        Text("点「添加 App」会从访达选一个 .app，自动填入其 Bundle ID；该 App 未安装时右键会自动用系统默认程序打开。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    MenuSectionCard(title: "尚未实现") {
                        Text("以下动作还没有做进右键服务，这里只列出计划，暂时无法配置或使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(roadmapItems, id: \.label) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "circle.dashed")
                                        .foregroundStyle(.tertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.label)
                                            .foregroundStyle(.secondary)
                                        Text(item.note)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Text("未实现")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(
                                            Color.primary.opacity(0.07),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .onChange(of: config) { config.save() }
    }

    // MARK: - 模板选项 / 路线图（与实现保持一致）

    private let templateOptions: [(key: String, label: String)] = [
        ("xlsx", "Microsoft Excel 工作簿 (.xlsx)"),
        ("docx", "Microsoft Word 文档 (.docx)"),
        ("pptx", "Microsoft PowerPoint 演示文稿 (.pptx)"),
        ("txt", "文本文档 (.txt)"),
        ("md", "Markdown (.md)")
    ]

    private let roadmapItems: [(label: String, note: String)] = [
        ("显示 / 隐藏隐藏文件", "需重启访达才能生效"),
        ("在终端中打开当前目录", "待确认默认终端的选择方式")
    ]

    // MARK: - 文件选择面板

    private func pickDirectory() {
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.title = "选择 App"
        if panel.runModal() == .OK, let url = panel.url {
            let bundleId = Bundle(url: url)?.bundleIdentifier ?? ""
            config.openWithApps.append(OpenWithApp(name: url.deletingPathExtension().lastPathComponent, bundleId: bundleId))
        }
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
