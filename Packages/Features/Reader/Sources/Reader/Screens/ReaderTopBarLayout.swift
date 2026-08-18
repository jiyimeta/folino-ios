import CoreGraphics

/// How the Reader's top strip divides into tiers, and what it costs the score.
///
/// The strip has two tiers and only one of them is paid for:
///
/// * the **cutout tier** is drawn inside the top safe area, flanking the display cutout, and adds nothing to the
///   score's inset — the system reserves that band whether or not anything is in it. It exists only where a tappable
///   control fits, which means a notched or Dynamic Island iPhone in portrait;
/// * the **control tier** sits below the safe area and is the only thing that adds inset.
///
/// The contract, and the reason this is a type rather than a few expressions inside a view: **the inset this strip
/// contributes is the control tier's height and nothing else** — independent of the device's safe area, of whether a
/// cutout tier is drawn, and of whether an edit session is running. That is what stops a paged score from
/// re-paginating when the user starts editing.
///
/// The contract is deliberately NOT "some total height stays constant". An earlier draft said that, on the premise
/// that hiding the status bar reclaims its height and the control tier can absorb it. It does not: on a device with a
/// display cutout the top inset belongs to the cutout, and the system keeps reserving it whether the status bar is
/// showing or not. That identity would have held only on an SE.
///
/// The Reader used to draw this chrome itself and exposed a flat `height: CGFloat = 52` that call sites subtracted
/// from the safe area. Every one of those broke when the standard toolbar replaced it. Callers ask here rather than
/// knowing a number.
enum ReaderTopBarLayout {
    /// The control tier's height: one row of 44pt controls plus the breathing room the old overlay used around them.
    static let controlTierHeight: CGFloat = 52

    /// The least top safe-area inset that can host a control. Below this the reserved band is a sliver — an SE's
    /// 20pt, an iPad's 24pt, nothing at all in landscape — and no cutout tier is drawn.
    static let minimumCutoutTierHeight: CGFloat = 44

    /// How far the cutout tier's two controls sit in from the screen's edges, and how tall they are drawn.
    ///
    /// Both measured off a Photos screenshot at this exact raster (1206x2622, iPhone 16 Pro): its ✕ occupies
    /// x 44…110pt and its 元に戻す x 293…357pt, so each is inset 45pt and 64–66pt wide; both are 26pt tall with their
    /// centres at 31.8pt, i.e. centred in the 62pt band. The tier is not styled by eye — these are the numbers.
    ///
    /// The inset is far wider than the 16pt a normal row uses, and deliberately so: the controls have to clear the
    /// cutout, whose width is not ours to know, and a generous margin is what keeps them clear of it on every model.
    /// The controls' own drawn size (26pt tall, 64pt minimum wide) comes from the same measurement but lives with
    /// the controls, in `EditorSessionBandMetrics` — Features don't import each other.
    static let cutoutTierHorizontalInset: CGFloat = 45

    /// Whether this device, in this orientation, reserves enough at the top to put controls there.
    static func hasCutoutTier(topSafeAreaInset: CGFloat) -> Bool {
        topSafeAreaInset >= minimumCutoutTierHeight
    }

    /// What the strip adds to the score's top inset. Constant by construction: the cutout tier is drawn inside space
    /// the system already reserved, so it is not part of this.
    ///
    /// The parameters are here because callers naturally have them and because the test asserts the result ignores
    /// them — a signature that took nothing would make the invariant unfalsifiable.
    static func contributedInset(topSafeAreaInset _: CGFloat, isEditing _: Bool) -> CGFloat {
        controlTierHeight
    }
}
