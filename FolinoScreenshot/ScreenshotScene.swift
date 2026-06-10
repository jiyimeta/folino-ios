import SwiftUI

enum ScreenshotScene: CaseIterable {
    case library
    case reader
    case playbackInspector
    case visualInspector
    case abRepeat
    case horizontal

    var id: String {
        switch self {
        case .library: "01_Library"
        case .reader: "02_Reader"
        case .playbackInspector: "03_PlaybackInspector"
        case .visualInspector: "04_VisualInspector"
        case .abRepeat: "05_ABRepeat"
        case .horizontal: "06_Horizontal"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .library: LibraryScene()
        case .reader: ReaderScene()
        case .playbackInspector: PlaybackInspectorScene()
        case .visualInspector: VisualInspectorScene()
        case .abRepeat: ABRepeatScene()
        case .horizontal: HorizontalScene()
        }
    }
}
