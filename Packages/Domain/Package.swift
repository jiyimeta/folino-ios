// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Domain",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            revision: "709e81e16ce85523207963a0b0de6283c5d49405",
        ),
    ],
    targets: [
        .target(
            name: "Domain",
            dependencies: [
                .product(name: "SheetMusicCore", package: "swift-sheet-music"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins,
        ),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
    ],
)
