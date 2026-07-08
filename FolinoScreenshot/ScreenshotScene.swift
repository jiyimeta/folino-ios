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

    @MainActor @ViewBuilder
    var view: some View {
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
