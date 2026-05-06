// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Reader",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Reader", targets: ["Reader"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
        .package(
            url: "git@github.com:jiyimeta/swift-sheet-music.git",
            revision: "9249f86543a9e2b7e6ba722c25c251ef47c33caa"
        ),
    ],
    targets: [
        .target(
            name: "Reader",
            dependencies: [
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
                .product(name: "SheetMusicUI", package: "swift-sheet-music"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins
        ),
        .testTarget(name: "ReaderTests", dependencies: ["Reader"]),
    ]
)
