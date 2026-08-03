import ScreenshotKit
import SwiftUI

enum ScreenshotScene: CaseIterable {
    case reader
    case playbackInspector
    case visualInspector
    case abRepeat
    case library
    case pip
    case annotation

    var id: String {
        switch self {
        case .reader: "01_Reader"
        case .playbackInspector: "02_PlaybackInspector"
        case .visualInspector: "03_VisualInspector"
        case .abRepeat: "04_ABRepeat"
        case .library: "05_Library"
        case .pip: "06_PiP"
        case .annotation: "07_Annotation"
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
        case .playbackInspector: PlaybackInspectorScene()
        case .visualInspector: VisualInspectorScene()
        case .abRepeat: ABRepeatScene()
        case .library: LibraryScene()
        case .pip: PiPScene()
        case .annotation: AnnotationScene()
        }
    }
}
