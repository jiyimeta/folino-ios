import ScreenshotKit
import SwiftUI
import UtilityUI

enum ScreenshotScene: CaseIterable {
    case reader
    case noteEditing
    case playbackInspector
    case visualInspector
    case abRepeat
    case library
    case pip
    case annotation

    var id: String {
        switch self {
        case .reader: "01_Reader"
        case .noteEditing: "02_NoteEditing"
        case .playbackInspector: "03_PlaybackInspector"
        case .visualInspector: "04_VisualInspector"
        case .abRepeat: "05_ABRepeat"
        case .library: "06_Library"
        case .pip: "07_PiP"
        case .annotation: "08_Annotation"
        }
    }

    /// The scene, with the idiom it should render for already installed, and the window's top safe area pinned to 0.
    ///
    /// **The inset is pinned for the same reason the idiom is installed here** — a scene is drawn into a mock device
    /// frame, not into the window. A screen that puts controls inside the top safe area (the Reader's cutout tier:
    /// ✕ and 完了 while editing) would place them in the window's 62pt band, which inside the frame is exactly where
    /// the screen's own control strip sits — the two came out overlapping. The frames draw no status-bar band
    /// (`innerStatusBarHeight: 0`, deliberate: the strip and the white score page read as one surface), so 0 is the
    /// truth here, and the controls fold into the strip the way they do on a phone with no cutout.
    ///
    /// The idiom is applied HERE, in app code, and not by the capture test: `ScreenshotKit` is statically linked into
    /// both the app and the test bundle, so each binary has its own `ScreenshotIdiomKey` metadata. An
    /// `.environment(\.screenshotIdiom, …)` written on the test side keys the test bundle's copy, and the scene —
    /// compiled into the app — reads the app's copy and silently gets the default (`.iPhone`). That produced iPad
    /// deliverables framed with the iPhone layout.
    @MainActor
    var view: some View {
        sceneBody
            .environment(\.screenshotIdiom, ScreenshotEnvironment.idiom)
            .environment(\.windowTopSafeAreaInsetOverride, 0)
            // The delivered pixels come from `simctl io screenshot`, which grabs the whole device screen — so the
            // simulator draws its Dynamic Island as a black pill over whatever the scene put up there, and
            // `ABRepeatScene`'s title (two subtitle lines, no bullets, so it sits highest) ran straight into it.
            //
            // Stated here rather than left to a scene: it used to be an accident. Scenes share one process, and the
            // editing scene hid the status bar as a side effect of its cutout tier — which happened to hold for
            // every scene captured after it, and for none captured before.
            .statusBarHidden(true)
    }

    @MainActor @ViewBuilder
    private var sceneBody: some View {
        switch self {
        case .reader: ReaderScene()
        case .noteEditing: NoteEditingScene()
        case .playbackInspector: PlaybackInspectorScene()
        case .visualInspector: VisualInspectorScene()
        case .abRepeat: ABRepeatScene()
        case .library: LibraryScene()
        case .pip: PiPScene()
        case .annotation: AnnotationScene()
        }
    }
}
