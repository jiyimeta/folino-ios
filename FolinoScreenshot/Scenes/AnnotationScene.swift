import Domain
import Reader
import ScreenshotKit
import SwiftUI

/// Marker class used to resolve the bundle that hosts `ScreenshotStrings.xcstrings`. See `LibraryScene` for the
/// rationale behind `.forClass` over `.atURL(Bundle.main.bundleURL)`.
private final class ScreenshotStringsAnchor {}

/// Marketing shot for the Apple Pencil annotation ("書き込み") feature.
///
/// HYBRID: the top chrome and bottom transport are the REAL live `ReaderRootScreen`, so they follow future app changes;
/// only the score + ink is a static **real-device capture**, fed in via `ReaderRootScreen(scoreContentOverride:)`. The
/// simulator can't render the score+ink itself — PencilKit ink doesn't composite there, `ImageRenderer` can't
/// rasterize the GPU-backed `ScoreView`, and the App-Store iPad size only has an iOS-27 simulator whose note spacing
/// differs from the iOS-26 device the ink was drawn on. A device screenshot is the only faithful source.
///
/// TO REFRESH THE CAPTURE (after editing the score or its annotation) — repeat per device (iPad mini, iPhone):
///  1. Build the main `Folino` app at the SAME swift-sheet-music revision this harness uses; install it on the device.
///  2. Open the score once normally and confirm Vertical layout mode with "honor layout breaks" ON (else the reflow
///     differs from the other scenes — an iPad with it off gave 6 bars/system instead of 3).
///  3. Relaunch in capture mode (hides chrome + transport so the grab is a clean score with no toolbar shadow):
///       xcrun devicectl device process launch --device <id> --terminate-existing --timeout 15 \
///         com.KeyNumber.Folino -- -readerCaptureMode 1
///     The `--` is REQUIRED so devicectl doesn't misparse the leading-dash app arg (else: "specify a 'timeout' value").
///  4. Open the score again, then capture:
///       xcrun devicectl device capture screenshot --device <id> --destination <path>.png
///  5. Crop off ONLY the iOS status bar (capture mode leaves no chrome, so it's a fixed height: iPad @2x ≈ 82px,
///     iPhone @3x ≈ 118px), saving as `Resources/annotated-device.png` (iPad) / `annotated-device-iphone.png` (phone).
///  6. Regenerate the framed PNGs with `Scripts/capture-screenshots.sh`. Capture is per-language, not per-scene, so
///     there is no single-scene run — `--devices <one> --locales en` is the fastest check, then the full sweep.
struct AnnotationScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    init() {
        ScreenshotSetup.ensure()
        // Vertical (matches the captured surface) with the full seek card so the transport shows the song's section
        // markers, mirroring the real reader the capture came from.
        UserDefaults.standard.set(ReaderLayoutMode.vertical.rawValue, forKey: ReaderGlobalSettingsKey.layoutMode)
        UserDefaults.standard.set(true, forKey: ReaderGlobalSettingsKey.showSeekBarEnabled)
    }

    var body: some View {
        ScreenshotSceneFrame(
            title: LocalizedStringResource(
                "scene.annotation.title",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            subtitle: LocalizedStringResource(
                "scene.annotation.subtitle",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            layout: FolinoScreenshotLayout.layout(for: idiom, subtitleBullet: true),
            idiom: idiom,
        ) {
            NavigationStack {
                ReaderRootScreen(
                    scoreItem: Fixture.items[0],
                    repository: FixtureScoreRepository(),
                    gateway: FixtureGateway(),
                    shareService: FixtureShareService(),
                    vocalTunerHandoff: NoopVocalTunerHandoff(),
                    metadataReader: FixtureMetadataReader(),
                    annotationCoordinator: .fixture,
                    scoresDirectory: URL(filePath: NSTemporaryDirectory()),
                    hidesBackButton: true,
                    scoreContentOverride: AnyView(deviceCapture),
                )
            }
        } overlay: {
            EmptyView()
        }
    }

    /// The real-device score+ink capture, standing in for the live (unreproducible) score surface.
    private var deviceCapture: some View {
        Group {
            if let img = UIImage(named: idiom == .iPad ? "annotated-device" : "annotated-device-iphone") {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Color.white
            }
        }
    }
}

#Preview("iPhone", traits: .appStoreIPhone) {
    AnnotationScene().environment(\.screenshotIdiom, .iPhone)
}

#Preview("iPad", traits: .appStoreIPad) {
    AnnotationScene().environment(\.screenshotIdiom, .iPad)
}
