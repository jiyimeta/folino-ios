import Foundation

/// A control's frame, in window coordinates. Four `Double`s rather than a `CGRect` because Android's Foundation
/// exports its own `CGRect`/`CGFloat` that silently shadow any same-named stub, so geometry that has to mean the same
/// thing on both platforms cannot be spelled in CG types — see the Android drift notes. iOS converts at the anchor
/// modifier; Android at the Compose `onGloballyPositioned`.
public struct ReaderHintRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double {
        x + width / 2
    }

    public var midY: Double {
        y + height / 2
    }

    public var minY: Double {
        y
    }

    public var maxY: Double {
        y + height
    }

    /// The same rect stated in a container whose own origin sits at `origin` in the shared window space.
    public func offset(byX dx: Double, y dy: Double) -> ReaderHintRect {
        ReaderHintRect(x: x + dx, y: y + dy, width: width, height: height)
    }
}

/// Where a bubble ends up for a given anchor and viewport.
public struct ReaderHintBubbleFrame: Equatable, Sendable {
    /// Rendered width of the card.
    public var width: Double
    /// Leading edge of the card, in the overlay's coordinate space.
    public var originX: Double
    /// How far the caret is shifted from the card's own center. Non-zero only when the card had to be clamped to a
    /// screen edge and the control it points at did not move with it.
    public var caretDX: Double
    public var placement: ReaderHintPlacement
    /// The card's caret-side edge: its TOP when `placement == .below`, its BOTTOM when `.above`. Height-independent
    /// on purpose — a long multi-line message must grow away from the anchor, not ride over it.
    public var edgeY: Double

    public init(width: Double, originX: Double, caretDX: Double, placement: ReaderHintPlacement, edgeY: Double) {
        self.width = width
        self.originX = originX
        self.caretDX = caretDX
        self.placement = placement
        self.edgeY = edgeY
    }
}

/// Every measurement a hint bubble is drawn from, and the arithmetic that places it against its anchor.
///
/// Shared rather than restated per platform because a coach mark that sits 14 pt from the edge on one and 16 dp on the
/// other is two features, and because the clamp below is the only part of the bubble anyone has ever gotten wrong: the
/// card stops at the screen edge while the caret keeps tracking the control, and those two clamps have to be
/// consistent or the arrow drifts off the card entirely.
public enum ReaderHintBubbleLayout {
    /// Gap between the caret apex and the control it points at.
    public static let caretGap: Double = 4
    /// Minimum margin between the card and the screen edge.
    public static let edgeMargin: Double = 14
    public static let maxBubbleWidth: Double = 280
    /// Keeps the caret at least `cornerRadius + halfCaret` from the card's corners, so the arrow never grows out of a
    /// rounded corner.
    public static let caretInset: Double = 24

    public static let caretWidth: Double = 18
    public static let caretHeight: Double = 8
    public static let cornerRadius: Double = 14

    public static let horizontalPadding: Double = 14
    public static let verticalPadding: Double = 11
    /// Gap between the title and the message.
    public static let titleMessageSpacing: Double = 3
    public static let titleFontSize: Double = 15
    public static let messageFontSize: Double = 13

    /// Appear / disappear duration for the bubble itself.
    public static let transitionDuration = 0.2
    /// The scale a bubble grows from (and shrinks to), anchored at its caret edge.
    public static let transitionScale = 0.94

    /// Places the card for `anchor`, expressed in the overlay's own coordinate space.
    ///
    /// - Parameters:
    ///   - anchor: the control's frame, already converted into the overlay's space.
    ///   - target: decides whether the card hangs below the control or floats above it.
    ///   - viewportWidth/viewportHeight: the overlay's size.
    public static func frame(
        anchor: ReaderHintRect,
        target: ReaderHintTarget,
        viewportWidth: Double,
        viewportHeight: Double,
    ) -> ReaderHintBubbleFrame {
        let width = min(maxBubbleWidth, viewportWidth - 2 * edgeMargin)
        let minCenterX = edgeMargin + width / 2
        let maxCenterX = viewportWidth - edgeMargin - width / 2
        let centerX = min(max(anchor.midX, minCenterX), max(minCenterX, maxCenterX))
        // The caret keeps tracking the control even when the card itself is clamped to a screen edge.
        let caretDX = min(max(anchor.midX - centerX, -width / 2 + caretInset), width / 2 - caretInset)
        let placement = target.placement(anchorMidY: anchor.midY, viewportHeight: viewportHeight)
        let edgeY = placement == .below ? anchor.maxY + caretGap : anchor.minY - caretGap
        return ReaderHintBubbleFrame(
            width: width,
            originX: centerX - width / 2,
            caretDX: caretDX,
            placement: placement,
            edgeY: edgeY,
        )
    }
}
