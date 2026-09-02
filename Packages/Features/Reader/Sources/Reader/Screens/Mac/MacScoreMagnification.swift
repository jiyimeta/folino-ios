import CoreGraphics

/// The zoom arithmetic behind the Mac reader's magnifying scroll host: the range it allows, and the conversion from a
/// click's reported location back into document coordinates.
///
/// **Deliberately outside `#if os(macOS)`.** Nothing here touches AppKit — it is `CGFloat` and `CGPoint` — and the
/// package's tests run on an iOS Simulator destination, so a macOS-gated helper would compile only where no test can
/// reach it. The one piece of behavior here that has bitten a reader is exactly the piece worth pinning with a test.
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

    /// Undo the magnification that SwiftUI folds into a click's location inside the hosted content.
    ///
    /// **A gesture location reported inside an `NSHostingView` under `NSScrollView.magnification` is the document
    /// point multiplied by the magnification, not the document point.** Measured, not assumed: a synthetic click aimed
    /// (through AppKit's own `convert(_:to:)`, which resolves it to the same hosting view AppKit's `hitTest` picks) at
    /// content point (120, 200) is reported by `SpatialTapGesture` as (120, 200) at 1x, (60, 100) at 0.5x and
    /// (240, 400) at 2x — and unchanged by scrolling the clip view, so the scroll offset is already accounted for and
    /// the magnification alone is not. AppKit implements magnification by scaling the CLIP view's bounds, which leaves
    /// the hosting view's own layout unscaled — that is why the engraving draws correctly at every zoom — while
    /// SwiftUI resolves the event against the scaled layer, so only the input coordinates carry the factor.
    ///
    /// Everything downstream — `nearestCursor`, `editingHitTest`, the page-band guard, the sticky-pane guard — speaks
    /// document coordinates, so this is the one conversion between the two.
    ///
    /// A non-positive or non-finite magnification cannot come from the scroll view (`minMagnification` is 0.25), and
    /// dividing by it would produce infinities that every downstream guard would then have to defend against; the
    /// point is passed through unchanged instead.
    static func documentPoint(fromHosted point: CGPoint, magnification: CGFloat) -> CGPoint {
        guard magnification > 0, magnification.isFinite else { return point }
        return CGPoint(x: point.x / magnification, y: point.y / magnification)
    }
}
