// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Infrastructure",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "CloudSync", targets: ["CloudSync"]),
        .library(name: "Soundfonts", targets: ["Soundfonts"]),
        .library(name: "Audio", targets: ["Audio"]),
        .library(name: "ScoreFiles", targets: ["ScoreFiles"]),
        .library(name: "CrashReporting", targets: ["CrashReporting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            revision: "9dcd11093bbc1e3a0a5704087299bc91b049f489",
        ),
        .package(path: "../Domain"),
        .package(path: "../Utility"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "11.0.0"),
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: [
                "Domain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            plugins: swiftLintPlugins,
        ),
        .target(name: "CloudSync", dependencies: ["Domain"], plugins: swiftLintPlugins),
        .target(
            name: "Soundfonts",
            dependencies: [
                "Domain",
                .product(name: "SheetMusicAudio", package: "swift-sheet-music"),
            ],
            plugins: swiftLintPlugins,
        ),
        .target(
            name: "Audio",
            dependencies: [
                "Domain",
                .product(name: "SheetMusicAudio", package: "swift-sheet-music"),
            ],
            plugins: swiftLintPlugins,
        ),
        .target(
            name: "ScoreFiles",
            dependencies: [
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "SheetMusic", package: "swift-sheet-music"),
                .product(name: "SheetMusicPDF", package: "swift-sheet-music"),
            ],
            plugins: swiftLintPlugins,
        ),
        .target(
            name: "CrashReporting",
            dependencies: [
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk"),
            ],
            plugins: swiftLintPlugins,
        ),
        .testTarget(
            name: "InfrastructureTests",
            dependencies: [
                "Persistence", "CloudSync", "Soundfonts", "Audio", "ScoreFiles",
                .product(name: "UtilityCore", package: "Utility"),
            ],
            resources: [.process("Resources")],
        ),
    ],
)
