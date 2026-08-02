import SwiftUI
import UIKit

/// Per-hint copy. Written as an explicit switch over literal keys rather than interpolating the hint's `rawValue`, so
/// Xcode's string extraction still sees every key and the String Catalog stays authoritative.
enum ReaderHintCopy {
    static func title(_ hint: ReaderFeatureHint) -> Text {
        switch hint {
        case .transportCollapse: Text("reader.hint.transportCollapse.title", bundle: .module)
        case .transportExpand: Text("reader.hint.transportExpand.title", bundle: .module)
        case .noteEditing: Text("reader.hint.noteEditing.title", bundle: .module)
        case .annotation: Text("reader.hint.annotation.title", bundle: .module)
        case .staffVisibility: Text("reader.hint.staffVisibility.title", bundle: .module)
        case .metronome: Text("reader.hint.metronome.title", bundle: .module)
        case .repeatPlayback: Text("reader.hint.repeatPlayback.title", bundle: .module)
        case .mixer: Text("reader.hint.mixer.title", bundle: .module)
        case .notePad: Text("reader.hint.notePad.title", bundle: .module)
        }
    }

    static func message(_ hint: ReaderFeatureHint) -> Text {
        switch hint {
        case .transportCollapse: Text("reader.hint.transportCollapse.message", bundle: .module)
        case .transportExpand: Text("reader.hint.transportExpand.message", bundle: .module)
        case .noteEditing: Text("reader.hint.noteEditing.message", bundle: .module)
        case .annotation: annotationMessage
        case .staffVisibility: Text("reader.hint.staffVisibility.message", bundle: .module)
        case .metronome: Text("reader.hint.metronome.message", bundle: .module)
        case .repeatPlayback: Text("reader.hint.repeatPlayback.message", bundle: .module)
        case .mixer: Text("reader.hint.mixer.message", bundle: .module)
        case .notePad: Text("reader.hint.notePad.message", bundle: .module)
        }
    }

    /// Only the iPad wording names Apple Pencil: an iPhone reader has no stylus to reach for, and mentioning one is
    /// noise in a bubble that has two lines to make its point.
    private static var annotationMessage: Text {
        UIDevice.current.userInterfaceIdiom == .pad
            ? Text("reader.hint.annotation.message.pad", bundle: .module)
            : Text("reader.hint.annotation.message.phone", bundle: .module)
    }
}
