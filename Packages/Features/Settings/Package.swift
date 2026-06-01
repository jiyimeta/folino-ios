// swift-tools-version: 6.3
import Foundation
import PackageDescription

/// When FOLINO_ANDROID=1 is exported, the manifest appends an Android-only JNI target
/// (FolinoSettingsJNI) plus the swift-java jextract plugin. iOS / xcodebuild builds never
/// set the env var, so they never see the JNI target or the swift-java dependency.
let isAndroid = ProcessInfo.processInfo.environment["FOLINO_ANDROID"] == "1"

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

var products: [Product] = [
    .library(name: "SettingsLogic", targets: ["SettingsLogic"]),
    .library(name: "Settings", targets: ["Settings"]),
]

var targets: [Target] = [
    .target(
        name: "SettingsLogic",
        dependencies: [
            "Domain",
            .product(name: "Wirelet", package: "swift-wirelet"),
        ],
        plugins: swiftLintPlugins,
    ),
    .target(
        name: "Settings",
        dependencies: [
            "SettingsLogic",
            "Domain",
            .product(name: "DeviceKit", package: "DeviceKit"),
            .product(name: "UtilityCore", package: "Utility"),
            .product(name: "UtilityUI", package: "Utility"),
            .product(name: "Yams", package: "Yams"),
        ],
        resources: [.process("Resources")],
        plugins: swiftLintPlugins,
    ),
    .testTarget(name: "SettingsTests", dependencies: ["Settings", "Domain"]),
    .testTarget(name: "SettingsLogicTests", dependencies: ["SettingsLogic", "Domain"]),
]

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/devicekit/devicekit", from: "5.8.0"),
    .package(url: "https://github.com/jpsim/Yams", from: "5.3.0"),
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
    // swift-wirelet v0.2.2 (pinned by revision, not semver) — matches the revision swift-sheet-music requires.
    // swiftlint:disable:next line_length
    .package(url: "https://github.com/jiyimeta/swift-wirelet.git", revision: "cd0d148e9d4dddad1c6afc47d5ef0a8d6f4a4a13"),
    .package(path: "../../Domain"),
    .package(path: "../../Utility"),
]

if isAndroid {
    packageDependencies += [
        .package(url: "https://github.com/swiftlang/swift-java.git", exact: "0.3.0"),
    ]
    products += [
        .library(
            name: "FolinoSettingsJNI",
            type: .dynamic,
            targets: ["FolinoSettingsJNI"],
        ),
    ]
    targets += [
        .target(
            name: "FolinoSettingsJNI",
            dependencies: [
                "SettingsLogic",
                .product(name: "Wirelet", package: "swift-wirelet"),
                .product(name: "SwiftJava", package: "swift-java"),
            ],
            exclude: [
                "swift-java.config",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            plugins: [
                .plugin(name: "JExtractSwiftPlugin", package: "swift-java"),
            ],
        ),
    ]
}

let package = Package(
    name: "Settings",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
)
