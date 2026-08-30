import EditorCore
import SwiftUI

// `EditorPadPlacement` itself lives in `EditorCore`, so the dock decision is one implementation both platforms
// run. What stays here is the part that only means something to SwiftUI.

extension EditorPadPlacement {
    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        }
    }
}
