import SwiftUI

enum ScreenshotScene: CaseIterable {
    case library
    case reader
    case horizontal

    var id: String {
        switch self {
        case .library: "01_Library"
        case .reader: "02_Reader"
        case .horizontal: "06_Horizontal"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .library: LibraryScene()
        case .reader: ReaderScene()
        case .horizontal: HorizontalScene()
        }
    }
}
