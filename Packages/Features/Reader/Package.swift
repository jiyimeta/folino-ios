// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Reader",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "Reader", targets: ["Reader"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            revision: "734abe52b7c57250205bb6d419e0d1935533cc96",
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
                .product(name: "SheetMusicLayoutApple", package: "swift-sheet-music"),
                .product(name: "SheetMusicMSCX", package: "swift-sheet-music"),
                .product(name: "SheetMusicUI", package: "swift-sheet-music"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins,
        ),
        .testTarget(name: "ReaderTests", dependencies: ["Reader"]),
    ],
)
