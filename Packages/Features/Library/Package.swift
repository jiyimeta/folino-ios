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
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.63.2"),
]

if isAndroid {
    // Android cross-compile path: the self-contained JNI target plus Domain
    // (Foundation + SheetMusicCore only, so it cross-compiles to Android and
    // builds on the macOS host for tests). Domain provides `ScorePresentation`,
    // the shared row-field derivation that keeps this store in lockstep with
    // the iOS Library. UtilityCore (Foundation-only) provides the shared
    // analytics catalog (`AnalyticsEvent`/`AnalyticsValue`) the analytics bridge
    // marshals across JNI; it already cross-compiles as a Domain dependency, so
    // only the `UtilityCore` product is pulled (never UtilityUI, which is SwiftUI).
    packageDependencies += [
        // swift-java 0.4.0's SwiftJavaTool is written against swift-subprocess 0.4.x; 0.5.0 removed APIs the
        // jextract tool needs under swift-6.3.3. Pin to 0.4.0, matching Reader / Editor / Settings — which is
        // what Editor's copy of this comment already claimed, though this package was in fact missing the pin
        // and only ever got 0.4.0 by way of whatever the transitive graph happened to resolve.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.4.0"),
        .package(url: "https://github.com/jiyimeta/swift-wirelet.git", exact: "0.5.0"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            exact: "2.4.1",
        ),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
    ]
    products += [
        .library(name: "FolinoLibraryJNI", type: .dynamic, targets: ["FolinoLibraryJNI"]),
    ]
    targets += [
        .target(
            name: "FolinoLibraryJNI",
            dependencies: [
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "Wirelet", package: "swift-wirelet"),
                .product(name: "WireletObservable", package: "swift-wirelet"),
                .product(name: "WireletProvided", package: "swift-wirelet"),
                .product(name: "SheetMusicMSCX", package: "swift-sheet-music"),
                .product(name: "SheetMusicMusicXML", package: "swift-sheet-music"),
                .product(name: "SheetMusicMIDI", package: "swift-sheet-music"),
                .product(name: "SheetMusicPDF", package: "swift-sheet-music"),
                // ssm's one format-dispatch, for every path here that reads a stored score file back without
                // knowing which of the six formats it is.
                .product(name: "SheetMusicLoader", package: "swift-sheet-music"),
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
        // ScoreUI is explicit, not merely transitive through Library: the tests import it directly to resolve
        // catalog display names (`localizedInstrumentName`) rather than hard-coding English.
        .testTarget(name: "LibraryTests", dependencies: ["Library", "ScoreUI"]),
    ]
}

let package = Package(
    name: "Library",
    defaultLocalization: "en",
    // macOS is BOTH real product support and a build floor. Sub-project IIIb forked the EditMode-driven
    // bulk-selection chrome behind `#if os(iOS)` and rebuilt it on a platform-neutral `isSelecting: Bool`, so
    // this package now compiles for macOS and is in Scripts/build-macos-packages.sh. (An earlier revision of
    // this comment said the opposite; it was written before that work landed.) The floor separately exists
    // because `FolinoLibraryJNI`, the Android cross-compile target above, depends on Domain and UtilityCore, both
    // of which declare `.macOS(.v15)`, and that Android graph's host tests build for macOS. Mirrors Utility and
    // Domain, which are in the same graph for the same reason. Do not remove this as unused platform support:
    // removing it once already broke `FOLINO_ANDROID=1 swift build --package-path Packages/Features/Library` with
    // "the library 'FolinoLibraryJNI' requires macos 10.13, but depends on the product 'Domain' which requires
    // macos 15.0" (and seven more of the same shape).
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
)
