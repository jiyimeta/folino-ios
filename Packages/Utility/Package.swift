// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Utility",
    defaultLocalization: "en",
    // macOS is declared purely as a build floor, not as a supported product platform: `UtilityCore` is in the
    // Android JNI dependency graph (shared analytics catalog), and that graph's tests build for the macOS host.
    // Without a floor at or above SwiftLintBuildToolPlugin's own (macOS 12) the manifest fails to resolve there.
    // Mirrors Domain, which is in the same graph for the same reason.
    platforms: [.iOS(.v18), .macOS(.v14)],
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
