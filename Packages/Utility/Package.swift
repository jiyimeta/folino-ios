// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Utility",
    defaultLocalization: "en",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "UtilityCore", targets: ["UtilityCore"]),
        .library(name: "UtilityUI", targets: ["UtilityUI"]),
        .library(name: "Navigation", targets: ["Navigation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.63.2"),
        .package(url: "https://github.com/devicekit/devicekit", from: "5.8.0"),
    ],
    targets: [
        .target(name: "UtilityCore", dependencies: [], plugins: swiftLintPlugins),
        .target(
            name: "UtilityUI",
            dependencies: [
                "UtilityCore",
                .product(name: "DeviceKit", package: "DeviceKit"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins,
        ),
        .target(name: "Navigation", dependencies: ["UtilityCore"], plugins: swiftLintPlugins),
        .testTarget(name: "UtilityCoreTests", dependencies: ["UtilityCore"]),
    ],
)
