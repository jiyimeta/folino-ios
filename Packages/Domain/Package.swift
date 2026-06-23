// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Domain",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.63.2"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            revision: "3f7884d7e70cb38376216a1983962716c3898c6a",
        ),
    ],
    targets: [
        .target(
            name: "Domain",
            dependencies: [
                .product(name: "SheetMusicCore", package: "swift-sheet-music"),
            ],
            plugins: swiftLintPlugins,
        ),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
    ],
)
