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
            deliverableSource: Self.deliverableSource(),
        )

        let scenes = ScreenshotScene.allCases.filter(Self.isRequested).map { scene in
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

    /// Whether this run was asked for `scene`.
    ///
    /// `Scripts/capture-screenshots.sh --scenes NoteEditing` writes the wanted names into the broker directory, and
    /// this filters `allCases` by them — so iterating on one shot costs one scene's capture rather than eight, in one
    /// language rather than five. Every other scene's PNG is simply left as it was. No file, or an empty one, means
    /// the whole set, which is what a plain run and an Xcode run both get.
    ///
    /// Matched case-insensitively against the scene id, so `--scenes 02` and `--scenes noteediting` both work.
    private static func isRequested(_ scene: ScreenshotScene) -> Bool {
        guard !requestedScenes.isEmpty else { return true }
        let id = scene.id.lowercased()
        return requestedScenes.contains { id.contains($0) }
    }

    private static let requestedScenes: [String] = {
        let list = repositoryRoot()
            .appendingPathComponent("fastlane/screenshots")
            .appendingPathComponent(".broker")
            .appendingPathComponent("scenes")
        guard let contents = try? String(contentsOf: list, encoding: .utf8) else { return [] }
        return contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }()

    /// Where the delivered pixels come from.
    ///
    /// `Scripts/capture-screenshots.sh` creates the broker directory for the length of a run and answers the markers
    /// this session writes into it with `simctl io … screenshot` grabs — the simulator's composited framebuffer,
    /// which is the only capture that carries real backdrop blur (the in-process rasterization draws the app's own
    /// layer tree, so a glass surface comes out tinted but unblurred, with the content behind it sharp).
    ///
    /// Keyed off the directory existing rather than an environment variable, because `xcodebuild
    /// test-without-building` gives no straightforward way to hand one to a hosted unit test — and because the
    /// fallback is then the right one by construction: run this test from Xcode, with no script around it, and there
    /// is no watcher to answer a marker, so it renders in-process instead of waiting for a frame that never comes.
    private static func deliverableSource() -> ScreenshotDeliverableSource {
        let broker = repositoryRoot()
            .appendingPathComponent("fastlane/screenshots")
            .appendingPathComponent(".broker")
        guard FileManager.default.fileExists(atPath: broker.path) else { return .drawHierarchy }
        return .hostCompositor(brokerDirectory: broker)
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
        repositoryRoot()
            .appendingPathComponent("fastlane/screenshots")
            .appendingPathComponent(AppStoreLocale.folder())
    }

    /// The checkout this test was compiled from — `#filePath` rather than anything runtime-derived, so it points at
    /// the right worktree even when several are on disk.
    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/FolinoScreenshotTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }
}
