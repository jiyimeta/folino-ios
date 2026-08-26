import SwiftUI

/// Which side edge the pad is tucked off, the way iOS PiP parks its window past the screen edge with only a pull tab
/// showing. Orthogonal to `EditorPadPlacement`: a tucked pad keeps its top / bottom dock, so pulling it back out lands
/// it where it was.
enum EditorPadTuckSide: String {
    case leading
    case trailing

    /// The pad edge the handle hangs off — the edge still facing the screen once the pad is offscreen. A pad tucked
    /// past the trailing edge shows its leading edge, and vice versa.
    var handleAlignment: Alignment {
        switch self {
        case .leading: .trailing
        case .trailing: .leading
        }
    }

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

    /// Horizontal offset from the pad's centered rest position that parks it fully past `side`'s screen edge, so the
    /// only thing left on screen is the handle hanging off its inner edge.
    static func restOffsetX(side: EditorPadTuckSide, viewportWidth: CGFloat, padWidth: CGFloat) -> CGFloat {
        let travel = (viewportWidth + padWidth) / 2
        return side == .trailing ? travel : -travel
    }

    /// Where an expanded pad's release lands it. Judged on the drag's projected travel so a flick toward an edge
    /// tucks without the finger covering the whole distance; a release inside the threshold is a reposition, not a
    /// dismissal, and returns `nil`.
    static func tuckDestination(projectedTranslationX: CGFloat, threshold: CGFloat) -> EditorPadTuckSide? {
        guard abs(projectedTranslationX) >= threshold else { return nil }
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
}
