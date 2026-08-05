import ScreenshotKit
import SwiftUI

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

    /// The scene, with the idiom it should render for already installed.
    ///
    /// The idiom is applied HERE, in app code, and not by the capture test: `ScreenshotKit` is statically linked into
    /// both the app and the test bundle, so each binary has its own `ScreenshotIdiomKey` metadata. An
    /// `.environment(\.screenshotIdiom, …)` written on the test side keys the test bundle's copy, and the scene —
    /// compiled into the app — reads the app's copy and silently gets the default (`.iPhone`). That produced iPad
    /// deliverables framed with the iPhone layout.
    @MainActor
    var view: some View {
        sceneBody.environment(\.screenshotIdiom, ScreenshotEnvironment.idiom)
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
