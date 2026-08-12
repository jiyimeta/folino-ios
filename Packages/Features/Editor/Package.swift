// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Editor",
    defaultLocalization: "en",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "Editor", targets: ["Editor"]),
        // Platform-neutral editing session logic. Foundation + Domain only — no SwiftUI, no Observation, no
        // SheetMusicUI — so the Android `FolinoEditorJNI` bridge (SP3) can link it alongside the Apple `Editor` UI
        // target. Mirrors `ReaderAnnotationCore` in the Reader package.
        .library(name: "EditorCore", targets: ["EditorCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            exact: "1.10.1",
        ),
    ],
    targets: [
        // No SwiftLint build-tool plugin: this target is cross-compiled for Android like `FolinoReaderJNI`, and the
        // plugin needs a macOS host context the Android SDK build can't satisfy. The pre-commit hook lints it on the
        // host instead.
        .target(
            name: "EditorCore",
            dependencies: ["Domain"],
        ),
        .target(
            name: "Editor",
            dependencies: [
                "Domain",
                "EditorCore",
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
                .product(name: "SheetMusicUI", package: "swift-sheet-music"),
                .product(name: "SheetMusicLayoutApple", package: "swift-sheet-music"),
            ],
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["EditorCore"],
        ),
    ],
)
