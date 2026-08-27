import SwiftUI

/// Which side edge the pad is tucked off, the way iOS PiP parks its window past the screen edge with only a pull tab
/// showing. Orthogonal to `EditorPadPlacement`: a tucked pad keeps its top / bottom dock, so pulling it back out lands
/// it where it was.
enum EditorPadTuckSide: String {
    case leading
    case trailing

    /// Points the way the pad will come out — inward, mirroring the PiP tab.
    var chevronSystemName: String {
        switch self {
        case .leading: "chevron.right"
        case .trailing: "chevron.left"
        }
    }
}

/// The geometry and release decisions behind the PiP-style tuck. Pure functions so the thresholds and the offset math
/// are testable without a gesture in the loop.
enum EditorPadTuckGeometry {
    /// How far a drag has to travel to change tuck state, in or out. Felt out as roughly a fifth of the portrait
    /// screen width; `min(width, height)` keeps it the same distance after a rotation.
    static func threshold(in viewport: CGSize) -> CGFloat {
        min(viewport.width, viewport.height) * 0.2
    }

    /// Horizontal offset from the pad's centered rest position that parks its CARD flush past `side`'s screen edge.
    /// `margin` is the layout frame's breathing room around the visible card (`EditorPadView.horizontalMargin`):
    /// the tuck aligns the card, not the frame — parking the frame left a margin-wide sliver of card showing, and a
    /// margin-wide gap between the card and the pull tab.
    static func restOffsetX(
        side: EditorPadTuckSide, viewportWidth: CGFloat, padWidth: CGFloat, margin: CGFloat,
    ) -> CGFloat {
        let travel = (viewportWidth + padWidth) / 2 - margin
        return side == .trailing ? travel : -travel
    }

    /// Where an expanded pad's release lands it. Judged on the drag's projected travel so a flick toward an edge
    /// tucks without the finger covering the whole distance; a release inside the threshold is a reposition, not a
    /// dismissal, and returns `nil`.
    ///
    /// Projection alone over-triggered: a fast, mostly-vertical dock flick amplifies its small sideways drift into a
    /// projected travel past the threshold, and the pad hid when the user meant to move it. So a tuck also needs the
    /// gesture to have been sideways in substance — either the finger ACTUALLY covered the threshold sideways (the
    /// deliberate drag toward an edge or corner), or the release velocity itself points more sideways than
    /// vertically (the quick short hide-flick, which never covers much distance).
    static func tuckDestination(
        translationX: CGFloat,
        projectedTranslationX: CGFloat,
        velocity: CGSize,
        threshold: CGFloat,
    ) -> EditorPadTuckSide? {
        guard abs(projectedTranslationX) >= threshold else { return nil }
        guard abs(translationX) >= threshold || abs(velocity.width) > abs(velocity.height) else { return nil }
        return projectedTranslationX > 0 ? .trailing : .leading
    }

    /// How far into the screen a tucked pad has been pulled, measured from its offscreen rest. Positive is inward;
    /// an outward push reads negative.
    static func inwardTravel(side: EditorPadTuckSide, translationX: CGFloat) -> CGFloat {
        side == .trailing ? -translationX : translationX
    }

    /// Whether releasing a tucked pad's drag brings it back out. Same threshold as tucking, same projection rule.
    static func restoresFromTuck(side: EditorPadTuckSide, projectedTranslationX: CGFloat, threshold: CGFloat) -> Bool {
        inwardTravel(side: side, translationX: projectedTranslationX) >= threshold
    }

    /// Whether the handle is showing at this instant of a tucked pad's drag. The handle previews the release: it stays
    /// up while letting go would snap back to hidden, and vanishes the moment the drag crosses into "this will stay
    /// out" territory — cross back and it returns, exactly the PiP tab's behavior.
    static func handleVisible(side: EditorPadTuckSide, translationX: CGFloat, threshold: CGFloat) -> Bool {
        inwardTravel(side: side, translationX: translationX) < threshold
    }

    /// The rest base for a tucked drag that has crossed the restore threshold: the tucked park shifted inward by
    /// exactly the handle's width, so the CARD's inner edge lands where the handle's inner edge is — the pad slides
    /// into the tab's own footprint and keeps tracking the finger from there, which is the PiP "the window attaches
    /// at the tab" impression. (Both edges move with the same live translation, so the alignment holds for the whole
    /// crossed stretch of the drag, not just the crossing instant.)
    static func restorePreviewRestOffsetX(
        side: EditorPadTuckSide, viewportWidth: CGFloat, padWidth: CGFloat, handleWidth: CGFloat, margin: CGFloat,
    ) -> CGFloat {
        let rest = restOffsetX(side: side, viewportWidth: viewportWidth, padWidth: padWidth, margin: margin)
        return side == .trailing ? rest - handleWidth : rest + handleWidth
    }
}
