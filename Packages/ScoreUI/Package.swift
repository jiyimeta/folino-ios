// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "ScoreUI",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "ScoreUI", targets: ["ScoreUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.63.2"),
        .package(path: "../Domain"),
        .package(path: "../Utility"),
    ],
    targets: [
        .target(
            name: "ScoreUI",
            dependencies: [
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins,
        ),
        .testTarget(name: "ScoreUITests", dependencies: ["ScoreUI"]),
    ],
)
