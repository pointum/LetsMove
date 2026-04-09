// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LetsMove",
    defaultLocalization: "en",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "LetsMove", targets: ["LetsMove"]),
    ],
    targets: [
        .target(
            name: "LetsMove",
            path: "Sources/LetsMove",
            resources: [.process("LetsMove.xcstrings")],
            publicHeadersPath: "include"
        ),
    ]
)
