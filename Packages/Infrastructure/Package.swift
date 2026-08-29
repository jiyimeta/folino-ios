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
    .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    .package(
        url: "https://github.com/jiyimeta/swift-sheet-music.git",
        exact: "2.1.0",
    ),
    .package(path: "../Domain"),
    .package(path: "../Utility"),
    .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: "11.15.0"),
]

var targets: [Target] = [
    .target(
        name: "Persistence",
        dependencies: [
            "Domain",
            .product(name: "UtilityCore", package: "Utility"),
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
    // Android cross-compile path: the self-contained `FolinoSoundfontJNI` JNI target. It pins the same
    // swift-wirelet revision as the Library and Reader JNI .so files (`ba1b8e33`), so the three agree on the
    // generated wire format. `FolinoSettingsJNI` is the odd one out — Settings pins `cd0d148e` (v0.2.2)
    // unconditionally, because `SettingsLogic` links Wirelet on the host side too.
    //
    // That skew is deliberate and safe, because the wire format only has to agree **within one module's JNI pair**,
    // not across the app: each `.so` links its own copy of the runtime statically and exchanges bytes solely with
    // the Kotlin codecs its own Gradle module generates. Settings is 0.2.2 on both sides (`FolinoSettingsAndroid`
    // applies the 0.2.2 plugin), Library and Reader are 0.3.2 on both sides, and no `@WireFormat` type crosses
    // between them — Settings' live in `SettingsLogic` (`GMDrumKitWire`, `VersionHistoryWire`) and are read by
    // nothing else. The one place the versions do meet is `wirelet-runtime` on the Kotlin classpath, where Gradle
    // resolves the app's conflicting 0.2.2 / 0.3.2 requests up to 0.3.2 — so the 0.2.2-generated Settings codecs
    // already compile and run against the newer runtime in every shipped build.
    //
    // Align them anyway when the Android note-editing branch lands, since it moves Infrastructure and Reader to
    // `exact: "0.5.0"` and re-pinning Settings in the same pass keeps one revision to reason about.
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
