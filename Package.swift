// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Foldesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Foldesk", targets: ["Foldesk"])
    ],
    targets: [
        .executableTarget(
            name: "Foldesk",
            path: "Sources/Foldesk",
            resources: [
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
