#if os(macOS)
import AppKit
import SwiftUI

/// The ground each Mac reading surface stands on.
///
/// **The paper is light because its content is; the ground is not paper, so it follows the system.** That split is the
/// whole design. The reader's justification for a fixed light appearance has only ever covered the sheet and what is
/// drawn on it — the paper is `Color.white` and ink is resolved against a light trait before it is stored. It says
/// nothing about the desk those sheets lie on, which is chrome: every Mac document viewer puts white pages on a dark
/// desk in dark mode, and a dark-mode reader that paints a light-grey desk is simply ignoring the setting.
///
/// * **A deck of sheets needs a desk.** In Page mode the sheets are objects with edges — a 0.5 pt border and a soft
///   shadow — and white paper on a white ground makes both invisible: one undifferentiated field with faint lines
///   ruled across it, and no way to see where a page ends. Light mode uses the 0.92 grey the reference implementation
///   (swift-sheet-music's macOS example) chose for exactly that. Dark mode uses a charcoal that separates the sheets
///   by contrast instead of by an edge — the border survives, the drop shadow does not read against it, and it does
///   not need to.
/// * **A continuous scroll has no desk at all.** Vertical mode's surface IS the paper: there are no page edges to
///   show, so it is white in both appearances, exactly as the iOS reader draws it. A grey surround there would draw a
///   boundary the content does not have, and an *adaptive* surround would darken half of a sheet the user is reading.
/// * **The original PDF takes the desk** — a PDF is a deck of pages by construction, and the reference did the same.
///
/// **One colour, two paint sites.** The deck's desk is a SwiftUI `.background`; the PDF's is `PDFView.backgroundColor`,
/// because `PDFView` paints an opaque background of its own and anything behind it would never be seen. Both read
/// `deskColor`, and it is an `NSColor` with an appearance-keyed provider rather than two hand-matched constants —
/// a SwiftUI `Color` and a hard-coded `NSColor` would drift apart the moment either appearance is retuned.
enum MacReaderGround {
    /// Behind a deck of sheets: the desk they lie on. Resolved per appearance, at draw time, by AppKit and SwiftUI
    /// alike (`Color(nsColor:)` carries the dynamic behaviour into the SwiftUI tree).
    static let deskColor = NSColor(name: "macReaderDesk") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 1)
            : NSColor(white: 0.92, alpha: 1)
    }

    /// The SwiftUI face of `deskColor`.
    static let desk = Color(nsColor: deskColor)

    /// Behind a continuous scroll: the paper itself, and therefore white in either appearance.
    static let paper = Color.white
}
#endif
