// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Foldesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Foldesk", targets: ["Foldesk"])
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
            resources: [
                .copy("Resources/Templates"),
                .copy("Resources/FoldeskIcon.png")
            ]
        ),
        .testTarget(
            name: "FoldeskTests",
            dependencies: ["Foldesk"],
            path: "Tests/FoldeskTests"
        )
    ]
)
