#if os(macOS)
import SwiftUI

/// The ground each Mac reading surface stands on.
///
/// **The root paints none of it.** `MacReaderRootScreen` pins the reader to a light appearance and stops there; the
/// ground is a property of what is being read, and the two modes want different ones:
///
/// * **A deck of sheets needs a desk.** In Page mode the sheets are objects with edges — a 0.5 pt border and a soft
///   shadow — and white paper on a white ground makes both invisible: the reader sees one undifferentiated field with
///   faint lines ruled across it, and cannot tell where one page ends. The reference implementation
///   (swift-sheet-music's macOS example) chose 0.92 grey for exactly this and it is what the desk is here too. Dark
///   grey — AppKit's own `underPageBackgroundColor`, Preview.app's choice — was rejected: this reader is pinned light
///   *because its content is light*, and a near-black desk under white paper is the light-content/dark-surround split
///   the pin exists to prevent.
/// * **A continuous scroll is one sheet.** Vertical mode has no page edges to show, so its ground is the paper: white,
///   edge to edge, exactly as the iOS reader does it. A grey surround there would draw a boundary where the content
///   has none.
///
/// The original-PDF view takes the desk too — a PDF is a deck of pages by construction.
enum MacReaderGround {
    /// Grey level of the desk. Kept as the raw number because AppKit wants an `NSColor(white:alpha:)` and SwiftUI
    /// wants a `Color`, and the two must not drift apart.
    static let deskWhite: CGFloat = 0.92

    /// Behind a deck of sheets: the desk they lie on.
    static let desk = Color(white: deskWhite)

    /// Behind a continuous scroll: the paper itself.
    static let paper = Color.white
}
#endif
