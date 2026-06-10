import ScreenshotKit
import SheetMusicLayoutApple
import SwiftUI

@main
struct ScreenshotApp: App {
    init() {
        // Install the CoreText-backed font-metrics provider before any score layout runs. The Reader's score
        // containers install this lazily when their `ScoreView`/`PagedScoreView` mounts, but `LayoutEngine` can run
        // (page-count / measure layout) before that, asserting if `FontMetrics.provider` is still the stub. Touch it
        // here so the provider is live for the whole process.
        _ = SheetMusicLayoutApple.install
        ScreenshotEnvironment.bootstrap(
            userDefaults: [
                // Suppress the Reader's first-run page-tap onboarding coachmarks (dashed tap-zone hints) so the
                // framed marketing shot shows a clean score. Key: `ReaderGlobalSettingsKey.pageTapHintDismissed`.
                "readerPageTapHintDismissed": true,
            ],
        )
    }

    var body: some Scene {
        WindowGroup {
            if let id = ScreenshotEnvironment.requestedSceneID,
               let scene = ScreenshotScene.allCases.first(where: { $0.id == id })
            {
                scene.view
                    .environment(\.screenshotIdiom, ScreenshotEnvironment.idiom)
            } else {
                Text("No scene requested")
            }
        }
    }
}
