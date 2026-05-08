// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Settings",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "Settings", targets: ["Settings"]),
    ],
    dependencies: [
        .package(url: "https://github.com/devicekit/devicekit", from: "5.8.0"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
    ],
    targets: [
        .target(
            name: "Settings",
            dependencies: [
                "Domain",
                .product(name: "DeviceKit", package: "DeviceKit"),
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins
        ),
        .testTarget(name: "SettingsTests", dependencies: ["Settings", "Domain"]),
    ]
)
