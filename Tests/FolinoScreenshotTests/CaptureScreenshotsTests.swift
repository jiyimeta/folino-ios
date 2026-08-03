@testable import FolinoScreenshot
import Foundation
import ScreenshotKit
import ScreenshotKitCapture
import XCTest

/// Captures every App Store screenshot scene in a single hosted-app process.
///
/// Replaces the old `FolinoUITests` capture loop, which relaunched the app once per (scene x language) — 70 launches
/// padded with fixed sleeps, and vulnerable to whatever the system decided to draw on top. Here the scenes are
/// swapped into the host app's own window and drawn straight out of it; see `ScreenshotCaptureSession` for the
/// mechanics and the `drawHierarchy` caveat.
///
/// Output goes directly into `fastlane/screenshots/<App Store locale>/<order>_<alias>_<scene>.png`, the layout
/// `fastlane deliver` already consumes — unchanged from the old pipeline, so nothing downstream had to move.
///
/// A language still needs its own process, so `Scripts/capture-screenshots.sh` runs this test once per
/// `-testLanguage`. Don't run it straight from Xcode expecting a full set: that captures one language, whichever the
/// scheme resolves.
@MainActor
final class CaptureScreenshotsTests: XCTestCase {
    func testCaptureAllScenes() throws {
        let idiom = ScreenshotEnvironment.idiom
        let session = try ScreenshotCaptureSession(
            idiom: idiom,
            outputDirectory: Self.outputDirectory(),
        )

        let scenes = ScreenshotScene.allCases.map { scene in
            // The closure is what defers each scene's `init` — every Folino scene seeds `UserDefaults` there, so
            // building them all up front would let the last one's seeding win for all seven.
            ScreenshotCaptureScene(id: scene.id) { scene.view }
        }

        try session.captureAll(
            scenes,
            filename: { "\($0.order)_\(Self.alias(for: idiom))_\($0.name).png" },
            resetSharedState: ScreenshotSharedState.reset,
        )
    }

    // MARK: - Output

    /// Device tag in the filename. Kept from the old `.screenshots.yml` destination aliases so the delivered files
    /// keep the names App Store Connect already has.
    private static func alias(for idiom: ScreenshotIdiom) -> String {
        idiom.pick(iPhone: "iPhone69", iPad: "iPad13")
    }

    /// `<repo>/fastlane/screenshots/<App Store locale>/`, created if missing.
    ///
    /// The simulator runs as the host user, so writing back into the checkout is allowed and keeps the pipeline to a
    /// single `xcodebuild test` — no result-bundle extraction, no `simctl get_app_container`.
    private static func outputDirectory() -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/FolinoScreenshotTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        return repositoryRoot
            .appendingPathComponent("fastlane/screenshots")
            .appendingPathComponent(AppStoreLocale.folder())
    }
}
