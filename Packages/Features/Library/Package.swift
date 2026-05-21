// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Library",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        // .dynamic causes SwiftPM to produce libLibraryLogic.so for Android and
        // a loadable .dylib on Apple platforms. The app target embeds it normally.
        .library(name: "LibraryLogic", type: .dynamic, targets: ["LibraryLogic"]),
        .library(name: "Library", targets: ["Library"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
    ],
    targets: [
        .target(
            name: "LibraryLogic",
            dependencies: ["Domain"],
            plugins: swiftLintPlugins,
        ),
        .target(
            name: "Library",
            dependencies: [
                "LibraryLogic",
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins,
        ),
        .testTarget(
            name: "LibraryLogicTests",
            dependencies: ["LibraryLogic", "Domain"],
        ),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
    ],
)
