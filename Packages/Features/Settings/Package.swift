// swift-tools-version: 6.3
import Foundation
import PackageDescription

/// When FOLINO_ANDROID=1 is exported, the manifest appends an Android-only JNI target
/// (FolinoSettingsJNI) plus the swift-java jextract plugin. iOS / xcodebuild builds never
/// set the env var, so they never see the JNI target or the swift-java dependency.
let isAndroid = ProcessInfo.processInfo.environment["FOLINO_ANDROID"] == "1"

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

var products: [Product] = [
    .library(name: "SettingsLogic", targets: ["SettingsLogic"]),
    .library(name: "Settings", targets: ["Settings"]),
]

var targets: [Target] = [
    .target(
        name: "SettingsLogic",
        dependencies: [
            "Domain",
            .product(name: "Wirelet", package: "swift-wirelet"),
            .product(name: "Yams", package: "Yams"),
        ],
        plugins: swiftLintPlugins,
    ),
    .target(
        name: "Settings",
        dependencies: [
            "SettingsLogic",
            "Domain",
            .product(name: "DeviceKit", package: "DeviceKit"),
            .product(name: "UtilityCore", package: "Utility"),
            .product(name: "UtilityUI", package: "Utility"),
            .product(name: "Yams", package: "Yams"),
        ],
        resources: [.process("Resources")],
        plugins: swiftLintPlugins,
    ),
    .testTarget(name: "SettingsTests", dependencies: ["Settings", "Domain"]),
    .testTarget(name: "SettingsLogicTests", dependencies: ["SettingsLogic", "Domain"]),
]

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/devicekit/devicekit", exact: "5.8.0"),
    .package(url: "https://github.com/jpsim/Yams", exact: "5.4.0"),
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.63.2"),
    // The same wirelet every other JNI `.so` in this app links. This package sat on v0.2.2 by revision
    // while Reader, Library, Editor and Infrastructure moved to 0.5.0, so one process carried two builds
    // of one package, each exporting the other's mangled names — 206 of them are defined by both this
    // `.so` and `libFolinoLibraryJNI.so`.
    //
    // That is a defect on its own terms and the reason for this pin, but it is NOT the cause of the heap
    // corruption it was found while chasing: every `Wirelet` symbol these images export has PROTECTED
    // visibility, so a reference inside a library always binds to that library's own definition and the
    // duplicate cannot be substituted. (The corruption was a stale SwiftPM `.build` producing a mixed
    // `libFolinoEditorJNI.so`; rebuilding the identical source fixed it.) Keep the versions aligned
    // anyway — the next skew may be between symbols that are not PROTECTED.
    .package(url: "https://github.com/jiyimeta/swift-wirelet.git", exact: "0.5.0"),
    .package(path: "../../Domain"),
    .package(path: "../../Utility"),
]

if isAndroid {
    packageDependencies += [
        .package(url: "https://github.com/swiftlang/swift-java.git", exact: "0.4.0"),
        // swift-java 0.4.0's SwiftJavaTool is written against swift-subprocess 0.4.x
        // (`OutputProtocol.standardOutput` / `ErrorOutputProtocol.standardError`).
        // swift-subprocess 0.5.0 removed those static members, which breaks the
        // jextract tool's compile under the swift-6.3.3 toolchain. Pin to 0.4.0
        // (tag `0.4`) — the last release where that API still exists — so the
        // JExtractSwiftPlugin tool builds. Remove once swift-java ships a release
        // built against swift-subprocess 0.5+.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.4.0"),
    ]
    products += [
        .library(
            name: "FolinoSettingsJNI",
            type: .dynamic,
            targets: ["FolinoSettingsJNI"],
        ),
    ]
    targets += [
        .target(
            name: "FolinoSettingsJNI",
            dependencies: [
                // For the shared review-prompt cadence, so Android prompts on the same launches as iOS.
                "Domain",
                "SettingsLogic",
                .product(name: "Wirelet", package: "swift-wirelet"),
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
    name: "Settings",
    defaultLocalization: "en",
    platforms: [.iOS(.v18)],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
)
