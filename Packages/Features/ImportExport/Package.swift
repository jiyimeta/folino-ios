// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "ImportExport",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "ImportExport", targets: ["ImportExport"]),
        .library(name: "ImportExportAppGroup", targets: ["ImportExportAppGroup"]),
        .library(name: "ImportExportShareUI", targets: ["ImportExportShareUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
    ],
    targets: [
        .target(
            name: "ImportExportAppGroup",
            dependencies: ["Domain"],
            plugins: swiftLintPlugins,
        ),
        .target(
            name: "ImportExport",
            dependencies: [
                "ImportExportAppGroup",
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
            ],
            plugins: swiftLintPlugins,
        ),
        .target(
            name: "ImportExportShareUI",
            dependencies: [
                "ImportExportAppGroup",
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
            ],
            plugins: swiftLintPlugins,
        ),
        .testTarget(
            name: "ImportExportAppGroupTests",
            dependencies: ["ImportExportAppGroup"],
        ),
        .testTarget(
            name: "ImportExportTests",
            dependencies: ["ImportExport"],
        ),
        .testTarget(
            name: "ImportExportShareUITests",
            dependencies: ["ImportExportShareUI"],
        ),
    ],
)
