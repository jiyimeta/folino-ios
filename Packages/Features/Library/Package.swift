// swift-tools-version: 6.3
import Foundation
import PackageDescription

let isAndroid = ProcessInfo.processInfo.environment["FOLINO_ANDROID"] == "1"

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

/// The iOS Library target uses UIKit/SwiftUI APIs unavailable on macOS. When
/// building on the macOS host with FOLINO_ANDROID=1, we skip it so that
/// `swift test --filter LibraryAndroidStoreTests` can run without platform
/// errors in the unrelated iOS sources.
let includeIOSLibrary = !isAndroid

var products: [Product] = []
if includeIOSLibrary {
    products += [
        .library(name: "Library", targets: ["Library"]),
    ]
}

var targets: [Target] = []
if includeIOSLibrary {
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

var packageDependencies: [Package.Dependency] = []
if includeIOSLibrary {
    packageDependencies += [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
    ]
}

if isAndroid {
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
}

let package = Package(
    name: "Library",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
)
