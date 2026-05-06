// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Domain",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(
            url: "git@github.com:jiyimeta/swift-sheet-music.git",
            revision: "6efc2031a070205c52d328fdcae1f9680e0b2c91"
        ),
    ],
    targets: [
        .target(
            name: "Domain",
            dependencies: [
                .product(name: "SheetMusicCore", package: "swift-sheet-music"),
            ],
            plugins: swiftLintPlugins
        ),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
    ]
)
