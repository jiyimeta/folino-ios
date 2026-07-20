// swift-tools-version: 6.3
import Foundation
import PackageDescription

/// When FOLINO_ANDROID=1 is exported, the manifest adds the Swift→Kotlin JNI target (FolinoReaderJNI) plus the
/// swift-java jextract plugin. iOS / xcodebuild builds never set the env var, so they never see the JNI target or
/// the swift-java dependency — the Apple-only Reader target (SheetMusicUI / LayoutApple / SwiftUI) is unaffected.
let isAndroid = ProcessInfo.processInfo.environment["FOLINO_ANDROID"] == "1"

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.63.2"),
    .package(path: "../../Domain"),
    .package(path: "../../ScoreUI"),
    .package(path: "../../Utility"),
    .package(
        url: "https://github.com/jiyimeta/swift-sheet-music.git",
        exact: "1.2.3",
    ),
]

var products: [Product] = [
    .library(name: "Reader", targets: ["Reader"]),
]

var targets: [Target] = [
    // Platform-neutral annotation anchoring logic (InkStroke ⇄ MusicalAnchor). Foundation + Domain only, no PencilKit
    // / SheetMusicLayout, so BOTH the Apple `Reader` UI target and the Android `FolinoReaderJNI` bridge depend on it —
    // shared logic lives here, not inside the iOS-only `Reader` target. No SwiftLint build-tool plugin (it is
    // cross-compiled for Android like `FolinoReaderJNI`; the pre-commit hook lints it on the host instead).
    .target(
        name: "ReaderAnnotationCore",
        dependencies: ["Domain"],
    ),
    .target(
        name: "Reader",
        dependencies: [
            "Domain",
            "ReaderAnnotationCore",
            "ScoreUI",
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
    .testTarget(
        name: "ReaderTests",
        dependencies: ["Reader", "ReaderAnnotationCore"],
        resources: [.process("Resources")],
    ),
]

if isAndroid {
    packageDependencies += [
        .package(url: "https://github.com/swiftlang/swift-java.git", exact: "0.4.0"),
        // swift-java 0.4.0's SwiftJavaTool is written against swift-subprocess 0.4.x; 0.5.0 removed APIs the
        // jextract tool needs under swift-6.3.3. Pin to 0.4.0 (matches Settings/Library). Remove once swift-java
        // ships against swift-subprocess 0.5+.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.4.0"),
    ]
    products += [
        .library(
            name: "FolinoReaderJNI",
            type: .dynamic,
            targets: ["FolinoReaderJNI"],
        ),
    ]
    targets += [
        .target(
            name: "FolinoReaderJNI",
            dependencies: [
                "Domain",
                "ReaderAnnotationCore",
                .product(name: "SwiftJava", package: "swift-java"),
            ],
            exclude: [
                "swift-java.config",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            plugins: [
                .plugin(name: "JExtractSwiftPlugin", package: "swift-java"),
            ],
        ),
    ]
}

let package = Package(
    name: "Reader",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
)
