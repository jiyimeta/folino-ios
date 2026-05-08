// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Reader",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Reader", targets: ["Reader"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            revision: "f5f264a051ab0ada04074b0cfe085faae4d7420f"
        ),
    ],
    targets: [
        .target(
            name: "Reader",
            dependencies: [
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
                .product(name: "SheetMusicAudio", package: "swift-sheet-music"),
                .product(name: "SheetMusicUI", package: "swift-sheet-music"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins
        ),
        .testTarget(name: "ReaderTests", dependencies: ["Reader"]),
    ]
)
