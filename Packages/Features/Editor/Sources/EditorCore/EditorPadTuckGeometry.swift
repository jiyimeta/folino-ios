import Foundation

/// Which side edge the note-input pad is tucked off, the way a PiP window parks past the screen edge with only a
/// grab point showing. Orthogonal to the pad's vertical dock: a tucked pad keeps it, so pulling the pad back out
/// lands it where it was.
public enum EditorPadTuckSide: String, Sendable, CaseIterable {
    case leading
    case trailing

    /// The discriminator the JNI boundary speaks, for the reason every other enum crossing it is an integer: one
    /// spelling of the enum, not a second one in Kotlin. 0 = leading, 1 = trailing.
    public var rawIndex: Int32 {
        switch self {
        case .leading: 0
        case .trailing: 1
        }
    }

    public init(rawIndex: Int32) {
        self = rawIndex == 0 ? .leading : .trailing
    }
}

/// The geometry and release decisions behind the PiP-style tuck — pure functions, so the thresholds and the offset
/// math are testable without a gesture in the loop, and so **both platforms run one copy of them**.
///
/// `Double` rather than `CGFloat`, and no `CGSize`: this type is compiled into the `FolinoEditorJNI` image, where
/// CoreGraphics does not exist. The Apple side converts at its call sites.
///
/// The two platforms imitate their own OS's PiP dismissal, and the ONE place that differs is how much of the card
/// stays on screen when tucked — `restOffsetX`'s `peek`. iOS parks the card entirely offscreen and leaves a pull tab
/// (`EditorPadTuckHandle`); Android leaves a sliver of the pad itself and adds no handle. Everything else — the
/// threshold, what commits a tuck, what brings it back — is deliberately identical, because a gesture that felt
/// different on each platform would be a divergence nobody could point at a line for.
public enum EditorPadTuckGeometry {
    /// How far a drag has to travel to change tuck state, in or out. Felt out as roughly a fifth of the portrait
    /// screen width; `min(width, height)` keeps it the same distance after a rotation.
    public static func threshold(viewportWidth: Double, viewportHeight: Double) -> Double {
        min(viewportWidth, viewportHeight) * 0.2
    }

    /// Horizontal offset from the pad's centered rest position that parks its CARD past `side`'s screen edge.
    ///
    /// `margin` is the layout frame's breathing room around the visible card: the tuck aligns the card, not the
    /// frame — parking the frame left a margin-wide sliver of card showing, and a margin-wide gap between the card
    /// and whatever marks the tucked pad.
    ///
    /// `peek` is how much of the card deliberately stays on screen. Zero leaves the card fully offscreen (iOS, which
    /// puts a pull tab there instead); a positive value leaves that much of the pad itself visible past the edge
    /// (Android, whose PiP stashes a window the same way).
    public static func restOffsetX(
        side: EditorPadTuckSide, viewportWidth: Double, padWidth: Double, margin: Double, peek: Double = 0,
    ) -> Double {
        let travel = (viewportWidth + padWidth) / 2 - margin - peek
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
    public static func tuckDestination(
        translationX: Double,
        projectedTranslationX: Double,
        velocityX: Double,
        velocityY: Double,
        threshold: Double,
    ) -> EditorPadTuckSide? {
        guard abs(projectedTranslationX) >= threshold else { return nil }
        guard abs(translationX) >= threshold || abs(velocityX) > abs(velocityY) else { return nil }
        return projectedTranslationX > 0 ? .trailing : .leading
    }

    /// How far into the screen a tucked pad has been pulled, measured from its offscreen rest. Positive is inward;
    /// an outward push reads negative.
    public static func inwardTravel(side: EditorPadTuckSide, translationX: Double) -> Double {
        side == .trailing ? -translationX : translationX
    }

    /// Whether releasing a tucked pad's drag brings it back out. Same threshold as tucking, same projection rule.
    public static func restoresFromTuck(
        side: EditorPadTuckSide, projectedTranslationX: Double, threshold: Double,
    ) -> Bool {
        inwardTravel(side: side, translationX: projectedTranslationX) >= threshold
    }

    /// Whether the pull tab is showing at this instant of a tucked pad's drag. The tab previews the release: it stays
    /// up while letting go would snap back to hidden, and vanishes the moment the drag crosses into "this will stay
    /// out" territory — cross back and it returns, exactly the PiP tab's behavior.
    ///
    /// Apple-only in practice: Android's tucked pad IS its own grab point, so there is nothing to fade.
    public static func handleVisible(
        side: EditorPadTuckSide, translationX: Double, threshold: Double,
    ) -> Bool {
        inwardTravel(side: side, translationX: translationX) < threshold
    }

    /// The rest base for a tucked drag that has crossed the restore threshold: the tucked park shifted inward by
    /// exactly the handle's width, so the CARD's inner edge lands where the handle's inner edge is — the pad slides
    /// into the tab's own footprint and keeps tracking the finger from there, which is the PiP "the window attaches
    /// at the tab" impression. (Both edges move with the same live translation, so the alignment holds for the whole
    /// crossed stretch of the drag, not just the crossing instant.)
    ///
    /// Apple-only, for the same reason `handleVisible` is.
    public static func restorePreviewRestOffsetX(
        side: EditorPadTuckSide, viewportWidth: Double, padWidth: Double, handleWidth: Double, margin: Double,
    ) -> Double {
        let rest = restOffsetX(side: side, viewportWidth: viewportWidth, padWidth: padWidth, margin: margin)
        return side == .trailing ? rest - handleWidth : rest + handleWidth
    }
}
