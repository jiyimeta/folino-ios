// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Editor",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "Editor", targets: ["Editor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            revision: "be336454aa5400300a34b48eca14860d7ad4acbd",
        ),
    ],
    targets: [
        .target(
            name: "Editor",
            dependencies: [
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
                .product(name: "SheetMusicUI", package: "swift-sheet-music"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins,
        ),
        .testTarget(
            name: "EditorTests",
            dependencies: [
                "Editor",
                .product(name: "SheetMusicLayoutApple", package: "swift-sheet-music"),
            ],
        ),
    ],
)
