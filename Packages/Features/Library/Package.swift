// swift-tools-version: 6.3
import Foundation
import PackageDescription

let isAndroid = ProcessInfo.processInfo.environment["FOLINO_ANDROID"] == "1"

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

var products: [Product] = []
var targets: [Target] = []
var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
]

if isAndroid {
    // Android cross-compile path: the self-contained JNI target plus Domain
    // (Foundation + SheetMusicCore only, so it cross-compiles to Android and
    // builds on the macOS host for tests). Domain provides `ScorePresentation`,
    // the shared row-field derivation that keeps this store in lockstep with
    // the iOS Library. Utility (iOS-only SwiftUI) is still not pulled.
    packageDependencies += [
        // swiftlint:disable:next line_length
        .package(url: "https://github.com/jiyimeta/swift-wirelet.git", revision: "67c293fee5cd306c5b984604c14b9db5dd8665ee"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            revision: "70761806733a1e9cbbb58315bb4565ffd6c972df",
        ),
        .package(path: "../../Domain"),
    ]
    products += [
        .library(name: "FolinoLibraryJNI", type: .dynamic, targets: ["FolinoLibraryJNI"]),
    ]
    targets += [
        .target(
            name: "FolinoLibraryJNI",
            dependencies: [
                "Domain",
                .product(name: "Wirelet", package: "swift-wirelet"),
                .product(name: "WireletObservable", package: "swift-wirelet"),
                .product(name: "WireletProvided", package: "swift-wirelet"),
                .product(name: "SheetMusicMSCX", package: "swift-sheet-music"),
                .product(name: "SheetMusicMIDI", package: "swift-sheet-music"),
            ],
            plugins: [
                .plugin(name: "WireletObservableBridges", package: "swift-wirelet"),
                .plugin(name: "WireletProvidedBridges", package: "swift-wirelet"),
            ],
        ),
        .testTarget(
            name: "FolinoLibraryJNITests",
            dependencies: ["FolinoLibraryJNI"],
            resources: [.process("Resources")],
        ),
    ]
} else {
    packageDependencies += [
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
        .package(path: "../../ScoreUI"),
    ]
    products += [
        .library(name: "Library", targets: ["Library"]),
    ]
    targets += [
        .target(
            name: "Library",
            dependencies: [
                "Domain",
                "ScoreUI",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins,
        ),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
    ]
}

let package = Package(
    name: "Library",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
)
