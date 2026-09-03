// swift-tools-version: 6.3
import Foundation
import PackageDescription

/// When FOLINO_ANDROID=1 is exported, the manifest swaps the Apple-only `Editor` UI target (SheetMusicUI / SwiftUI)
/// for the Android JNI target (FolinoEditorJNI) instead of merely appending it, unlike Reader / Settings.
///
/// Those two packages' JNI targets touch no swift-sheet-music product at all, so they can add their JNI target
/// alongside an unconditional Apple target. `FolinoEditorJNI` cannot: it depends on `SheetMusicEditWire`, which ssm's
/// own manifest exports only when `SWIFT_SHEET_MUSIC_ANDROID=1` — and under that same flag ssm stops exporting
/// `SheetMusicUI` / `SheetMusicLayoutApple`, which `Editor` / `EditorTests` need. Both cannot resolve in the same
/// evaluation of ssm's manifest, and `swift build` validates every LOCAL target's product dependencies regardless of
/// which `--product` was requested — so the two halves must be mutually exclusive branches here, matching how
/// `Packages/Features/Library/Package.swift` already splits `Library`/`LibraryTests` from `FolinoLibraryJNI`.
/// `EditorCore` depends on nothing from ssm, so it stays common to both branches, exactly as `ReaderAnnotationCore`
/// does in Reader.
let isAndroid = ProcessInfo.processInfo.environment["FOLINO_ANDROID"] == "1"

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.63.2"),
    .package(path: "../../Domain"),
    .package(path: "../../Utility"),
    .package(path: "../../ScoreUI"),
    .package(
        url: "https://github.com/jiyimeta/swift-sheet-music.git",
        exact: "2.4.1",
    ),
]

var products: [Product] = [
    // Platform-neutral editing session logic. Foundation + Domain only — no SwiftUI, no Observation, no
    // SheetMusicUI — so the Android `FolinoEditorJNI` bridge (SP3) can link it alongside the Apple `Editor` UI
    // target. Mirrors `ReaderAnnotationCore` in the Reader package.
    .library(name: "EditorCore", targets: ["EditorCore"]),
]

var targets: [Target] = [
    // No SwiftLint build-tool plugin: this target is cross-compiled for Android like `FolinoReaderJNI`, and the
    // plugin needs a macOS host context the Android SDK build can't satisfy. The pre-commit hook lints it on the
    // host instead.
    .target(
        name: "EditorCore",
        dependencies: ["Domain"],
    ),
    .testTarget(
        name: "EditorCoreTests",
        dependencies: ["EditorCore"],
    ),
]

if isAndroid {
    packageDependencies += [
        .package(url: "https://github.com/swiftlang/swift-java.git", exact: "0.4.0"),
        // swift-java 0.4.0's SwiftJavaTool is written against swift-subprocess 0.4.x; 0.5.0 removed APIs the
        // jextract tool needs under swift-6.3.3. Pin to 0.4.0 (matches Reader / Settings / Library).
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.4.0"),
        .package(
            url: "https://github.com/jiyimeta/swift-wirelet.git",
            exact: "0.5.0",
        ),
    ]
    products += [
        .library(
            name: "FolinoEditorJNI",
            type: .dynamic,
            targets: ["FolinoEditorJNI"],
        ),
    ]
    targets += [
        .target(
            name: "FolinoEditorJNI",
            dependencies: [
                "Domain",
                "EditorCore",
                // The score this session edits is parsed and re-encoded inside THIS image: spec §3 — a `Score`
                // cannot cross between the two `SheetMusicCore` copies in the process, only bytes can.
                .product(name: "SheetMusicMSCX", package: "swift-sheet-music"),
                // Which parser a score file belongs to is decided by ssm's one format-dispatch, not by a second
                // spelling here. Static on purpose: it compiles into this `.so`'s own SheetMusicCore copy, which is
                // exactly what the two-copies rule above requires — the Reader's `ScoreBridge` is a `.dynamic` `.so`
                // and could not be linked without breaking it.
                .product(name: "SheetMusicLoader", package: "swift-sheet-music"),
                // The intent wire has exactly one declaration, in ssm, and both `.so`s link it (spec §5.4).
                .product(name: "SheetMusicEditWire", package: "swift-sheet-music"),
                .product(name: "SwiftJava", package: "swift-java"),
                .product(name: "Wirelet", package: "swift-wirelet"),
                .product(name: "WireletObservable", package: "swift-wirelet"),
                .product(name: "WireletProvided", package: "swift-wirelet"),
            ],
            exclude: [
                "swift-java.config",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            plugins: [
                .plugin(name: "JExtractSwiftPlugin", package: "swift-java"),
                .plugin(name: "WireletObservableBridges", package: "swift-wirelet"),
                .plugin(name: "WireletProvidedBridges", package: "swift-wirelet"),
            ],
        ),
    ]
} else {
    products += [
        .library(name: "Editor", targets: ["Editor"]),
    ]
    targets += [
        .target(
            name: "Editor",
            dependencies: [
                "Domain",
                "EditorCore",
                "ScoreUI",
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
    ]
}

let package = Package(
    name: "Editor",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
)
