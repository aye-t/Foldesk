import SwiftUI
import AppKit

struct FinderMenuPage: View {
    private let templateOptions: [(key: String, label: String)] = [
        ("xlsx", "Microsoft Excel 工作簿 (.xlsx)"),
        ("docx", "Microsoft Word 文档 (.docx)"),
        ("pptx", "Microsoft PowerPoint 演示文稿 (.pptx)"),
        ("txt", "文本文档 (.txt)"),
        ("md", "Markdown (.md)")
    ]

    /// 尚未实现的动作。仅作路线图展示，不提供任何可写入的配置入口——
    /// 此前这里放了「常用目录 / 用指定 App 打开」的增删 UI，
    /// 但写出的 findersync.json 没有任何服务消费，属于会误导用户的死配置。
    private let roadmapItems: [(label: String, note: String)] = [
        ("复制到 / 移动到指定目录", "需要在服务中维护目标目录列表"),
        ("用指定 App 打开", "需要在服务中维护 App 列表"),
        ("显示 / 隐藏隐藏文件", "需重启访达才能生效"),
        ("在终端中打开当前目录", "待确认默认终端的选择方式")
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
