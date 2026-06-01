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
    // Android cross-compile path: only the self-contained JNI target. It does
    // NOT depend on Domain/Utility, so they are never pulled — the macOS host
    // build (used for cross-compile + host tests) stays free of the iOS-only
    // SwiftUI `Library` target, and the shared packages need no changes.
    packageDependencies += [
        // swiftlint:disable:next line_length
        .package(url: "https://github.com/jiyimeta/swift-wirelet.git", revision: "cd0d148e9d4dddad1c6afc47d5ef0a8d6f4a4a13"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            revision: "2f7128fae3b8e30371c2528a831a1ebf51e84891",
        ),
    ]
    products += [
        .library(name: "FolinoLibraryJNI", type: .dynamic, targets: ["FolinoLibraryJNI"]),
    ]
    targets += [
        .target(
            name: "FolinoLibraryJNI",
            dependencies: [
                .product(name: "Wirelet", package: "swift-wirelet"),
                .product(name: "WireletObservable", package: "swift-wirelet"),
                .product(name: "SheetMusicMSCX", package: "swift-sheet-music"),
            ],
            plugins: [
                .plugin(name: "WireletObservableBridges", package: "swift-wirelet"),
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
    ]
    products += [
        .library(name: "Library", targets: ["Library"]),
    ]
    targets += [
        .target(
            name: "Library",
            dependencies: [
                "Domain",
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
