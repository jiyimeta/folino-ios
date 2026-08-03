import Domain
import Foundation

// `RepeatModeStorage` is internal to Reader; the FolinoScreenshot target builds Debug, so testability is available
// (mirrors what the inspector scenes already do).
@testable import Reader

/// Keeps app-wide state from leaking between scenes, so capturing every scene in one process matches capturing each
/// in a fresh one.
///
/// The old pipeline got this for free: one app launch per scene, so a scene's `init` was always writing onto a fresh
/// `UserDefaults`. In-process, whatever the previous scene wrote is still there — and the keys below are exactly the
/// ones scenes disagree about (`AnnotationScene` wants the seek card, everything else wants the compact pill;
/// `ABRepeatScene` wants `.abLoop`, `PlaybackInspectorScene` wants `.off`).
///
/// Reset clears rather than re-seeds, so each scene starts from the app's own defaults and its `init` puts back only
/// what it actually cares about. A scene that forgets to pin a key therefore shows the shipping default, not the
/// previous scene's choice.
enum ScreenshotSharedState {
    @MainActor
    static func reset() {
        UserDefaults.standard.removeObject(forKey: ReaderGlobalSettingsKey.layoutMode)
        UserDefaults.standard.removeObject(forKey: ReaderGlobalSettingsKey.showSeekBarEnabled)
        RepeatModeStorage.set(.off)
    }
}
