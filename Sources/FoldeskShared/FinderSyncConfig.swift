import Foundation

/// 主 app 与 Finder Sync 扩展之间共享的配置文件模型。
/// 两者都直接读写同一个 JSON 文件，避免依赖 App Group（ad-hoc 签名下不可用）。
public struct FavoriteDir: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// 绝对路径，或带 ~ 的 home 路径。
    public var path: String

    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// “用指定 App 打开”中的一项。
public struct OpenWithApp: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// App 的 bundle identifier；若该 App 未安装则可退化为绝对路径。
    public var bundleId: String

    public init(id: UUID = UUID(), name: String, bundleId: String) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
    }
}

/// 各文件操作类菜单项的独立开关。缺省全部开启。
public struct Features: Codable {
    public var copyName: Bool
    public var sendAliasToDesktop: Bool
    public var compress: Bool
    public var extract: Bool
    public var permanentDelete: Bool
    public var openWithEnabled: Bool

    public init(
        copyName: Bool = true,
        sendAliasToDesktop: Bool = true,
        compress: Bool = true,
        extract: Bool = true,
        permanentDelete: Bool = true,
        openWithEnabled: Bool = true
    ) {
        self.copyName = copyName
        self.sendAliasToDesktop = sendAliasToDesktop
        self.compress = compress
        self.extract = extract
        self.permanentDelete = permanentDelete
        self.openWithEnabled = openWithEnabled
    }
}

public struct FinderSyncConfig: Codable {
    public var enabled: Bool
    public var favoriteDirs: [FavoriteDir]
    /// 新建文件模板开关，键：xlsx / docx / pptx / txt / md / empty
    public var newFileTemplates: [String: Bool]
    public var features: Features
    public var openWithApps: [OpenWithApp]

    /// 显式成员初始化器（自定义 init(from:) 会抑制编译器合成，这里补回以便 `default` 等使用）。
    public init(
        enabled: Bool,
        favoriteDirs: [FavoriteDir],
        newFileTemplates: [String: Bool],
        features: Features,
        openWithApps: [OpenWithApp]
    ) {
        self.enabled = enabled
        self.favoriteDirs = favoriteDirs
        self.newFileTemplates = newFileTemplates
        self.features = features
        self.openWithApps = openWithApps
    }

    public static var `default`: FinderSyncConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return FinderSyncConfig(
            enabled: true,
            favoriteDirs: [
                FavoriteDir(name: "下载", path: home + "/Downloads"),
                FavoriteDir(name: "桌面", path: home + "/Desktop"),
                FavoriteDir(name: "文稿", path: home + "/Documents")
            ],
            newFileTemplates: [
                "xlsx": true, "docx": true, "pptx": true,
                "txt": true, "md": true, "empty": true
            ],
            features: Features(),
            openWithApps: [
                OpenWithApp(name: "Visual Studio Code", bundleId: "com.microsoft.VSCode"),
                OpenWithApp(name: "Typora", bundleId: "abnerworks.Typora"),
                OpenWithApp(name: "预览", bundleId: "com.apple.Preview")
            ]
        )
    }

    public static var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Foldesk/findersync.json")
    }

    /// 兼容旧配置：缺失新字段时回退到默认值，而不是整体解析失败。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        favoriteDirs = try c.decodeIfPresent([FavoriteDir].self, forKey: .favoriteDirs) ?? Self.default.favoriteDirs
        newFileTemplates = try c.decodeIfPresent([String: Bool].self, forKey: .newFileTemplates) ?? Self.default.newFileTemplates
        features = try c.decodeIfPresent(Features.self, forKey: .features) ?? Features()
        openWithApps = try c.decodeIfPresent([OpenWithApp].self, forKey: .openWithApps) ?? Self.default.openWithApps
    }

    /// 读取配置；文件不存在或解析失败时回退到默认配置。
    public static func load() -> FinderSyncConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(FinderSyncConfig.self, from: data) else {
            return .default
        }
        return cfg
    }

    public func save() {
        let url = Self.configURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url)
        }
    }
}
