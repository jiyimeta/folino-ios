import Foundation
import SheetMusicLayoutApple

/// Shared, idempotent setup that every screenshot scene needs in order to render
/// real notation — installed from BOTH `ScreenshotApp.init` (the live capture run)
/// and each scene's `init` (so SwiftUI `#Preview`, which never runs the `App`'s
/// `init`, also renders the score instead of an empty staff).
enum ScreenshotSetup {
    static func ensure() {
        // Install the CoreText-backed font-metrics provider before any score layout
        // runs. `LayoutEngine` (page-count / measure layout) can run before a score
        // container mounts and asserts / renders empty if `FontMetrics.provider` is
        // still the stub. `install` is idempotent, so repeated calls are harmless.
        _ = SheetMusicLayoutApple.install

        // Suppress the Reader's first-run page-tap onboarding coachmarks so the
        // framed marketing shot shows a clean score.
        UserDefaults.standard.register(defaults: [
            "readerPageTapHintDismissed": true,
        ])
    }
}
