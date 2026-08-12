// swift-tools-version: 6.3
import Foundation
import PackageDescription

let isAndroid = ProcessInfo.processInfo.environment["FOLINO_ANDROID"] == "1"

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

var products: [Product] = [
    .library(name: "Persistence", targets: ["Persistence"]),
    .library(name: "CloudSync", targets: ["CloudSync"]),
    .library(name: "Soundfonts", targets: ["Soundfonts"]),
    .library(name: "Audio", targets: ["Audio"]),
    .library(name: "ScoreFiles", targets: ["ScoreFiles"]),
    .library(name: "CrashReporting", targets: ["CrashReporting"]),
    .library(name: "Analytics", targets: ["Analytics"]),
]

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.63.2"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    .package(
        url: "https://github.com/jiyimeta/swift-sheet-music.git",
        exact: "1.12.0",
    ),
    .package(path: "../Domain"),
    .package(path: "../Utility"),
    .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "11.0.0"),
]

var targets: [Target] = [
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
            // Pure-Swift, MIT SoundFont2 synth. Injected into the live `PlaybackEngine` to replace the built-in
            // AUMIDISynth path, whose voice stealing dropped notes in dense passages (App Store dropout regression).
            .product(name: "SheetMusicAudioSwiftySynth", package: "swift-sheet-music"),
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
    .target(
        name: "Analytics",
        dependencies: [
            .product(name: "UtilityCore", package: "Utility"),
            .product(name: "FirebaseAnalytics", package: "firebase-ios-sdk"),
        ],
        plugins: swiftLintPlugins,
    ),
    .testTarget(
        name: "InfrastructureTests",
        dependencies: [
            "Persistence", "CloudSync", "Soundfonts", "Audio", "ScoreFiles",
            "Analytics",
            .product(name: "UtilityCore", package: "Utility"),
        ],
        resources: [.process("Resources")],
    ),
]

if isAndroid {
    // Android cross-compile path: the self-contained `FolinoSoundfontJNI` JNI target. It pins the SAME
    // swift-wirelet revision as the Library JNI .so so both dynamic libraries share one wirelet runtime.
    // Domain (already a path dependency above) provides the shared `SoundfontDownloadReducer` / state / preset
    // types so download behavior matches iOS exactly.
    packageDependencies += [
        // swiftlint:disable:next line_length
        .package(url: "https://github.com/jiyimeta/swift-wirelet.git", revision: "ba1b8e337a508079c5213656e4c01e9edbedc8b4"),
    ]
    products += [
        .library(name: "FolinoSoundfontJNI", type: .dynamic, targets: ["FolinoSoundfontJNI"]),
    ]
    targets += [
        .target(
            name: "FolinoSoundfontJNI",
            dependencies: [
                "Domain",
                .product(name: "Wirelet", package: "swift-wirelet"),
                .product(name: "WireletObservable", package: "swift-wirelet"),
                .product(name: "WireletProvided", package: "swift-wirelet"),
            ],
            plugins: [
                .plugin(name: "WireletObservableBridges", package: "swift-wirelet"),
                .plugin(name: "WireletProvidedBridges", package: "swift-wirelet"),
            ],
        ),
    ]
}

let package = Package(
    name: "Infrastructure",
    platforms: [.iOS(.v18)],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
)
