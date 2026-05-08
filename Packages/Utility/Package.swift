// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Utility",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "UtilityCore", targets: ["UtilityCore"]),
        .library(name: "UtilityUI", targets: ["UtilityUI"]),
        .library(name: "Navigation", targets: ["Navigation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
    ],
    targets: [
        .target(name: "UtilityCore", dependencies: [], plugins: swiftLintPlugins),
        .target(
            name: "UtilityUI",
            dependencies: ["UtilityCore"],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins
        ),
        .target(name: "Navigation", dependencies: ["UtilityCore"], plugins: swiftLintPlugins),
        .testTarget(name: "UtilityCoreTests", dependencies: ["UtilityCore"]),
    ]
)
