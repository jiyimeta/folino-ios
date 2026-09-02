import CoreGraphics

/// The magnification range the Mac reader's scroll hosts allow, and the clamp that keeps a computed fit inside it.
///
/// **Deliberately outside `#if os(macOS)`.** Nothing here touches AppKit — it is `CGFloat` — and the package's tests
/// run on an iOS Simulator destination, so a macOS-gated helper would compile only where no test can reach it.
///
/// There is no "convert a click by the magnification" helper here, and that absence is deliberate: a click's location
/// under `NSScrollView.magnification` cannot be recovered by arithmetic, because SwiftUI delivers it to the wrong view
/// in the first place. `MacScoreClickMapping` carries that measurement and the route that replaced it.
enum MacScoreMagnification {
    /// The magnification range the host allows, carried by the reference implementation. 0.25 is small enough to see
    /// a multi-page spread at once; 4.0 is where the engraving is being inspected rather than read. Named here so the
    /// container can clamp its own fit-to-window seed against the same numbers the scroll view enforces.
    static let minimum: CGFloat = 0.25
    static let maximum: CGFloat = 4.0

    /// Bring a computed fit into the range the scroll view will accept.
    ///
    /// The two seeds that call this stay separate on purpose: the page deck fits a fixed sheet on BOTH axes inside a
    /// deck-padded viewport, horizontal mode fits only the strip's HEIGHT inside an inset one. Only the clamp is
    /// common, and folding two different fits into one function would take more arguments than it saves lines.
    static func clamped(_ magnification: CGFloat) -> CGFloat {
        min(max(magnification, minimum), maximum)
    }
}
