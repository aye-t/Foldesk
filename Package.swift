// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Foldesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Foldesk", targets: ["Foldesk"]),
        .executable(name: "FoldeskFinderSync", targets: ["FoldeskFinderSync"])
    ],
    targets: [
        .target(
            name: "FoldeskShared",
            path: "Sources/FoldeskShared"
        ),
        .executableTarget(
            name: "Foldesk",
            dependencies: ["FoldeskShared"],
            path: "Sources/Foldesk",
            exclude: [
                "Resources/Templates"
            ],
            resources: [
                .copy("Resources/FoldeskIcon.png")
            ]
        ),
        .executableTarget(
            name: "FoldeskFinderSync",
            dependencies: ["FoldeskShared"],
            path: "Sources/FoldeskFinderSync",
            exclude: [
                "Info.plist",
                "Resources/Templates"
            ]
        ),
        .testTarget(
            name: "FoldeskTests",
            dependencies: ["Foldesk"],
            path: "Tests/FoldeskTests"
        )
    ]
)
