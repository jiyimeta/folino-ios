import CoreGraphics
import SwiftUI

/// Every measurement that differs between the compact transport pill and the expanded seek card, resolved at an
/// arbitrary point between the two.
///
/// The card is laid out from these numbers rather than straight from a `Bool`, because a boolean has nothing to
/// interpolate. SwiftUI's *layout* animations are overwritten by any later layout pass that runs without an animation,
/// and while a finger is on the transport there is one of those every frame — which is why the card used to jump
/// between its two sizes in a single frame even though its glass crossfaded properly (opacity lives on the render node
/// and survived; the layout did not). Fed through `MorphReader`, `morph` is interpolated by the animation clock
/// instead, so every layout pass — animated or not — lays the card out at the size the animation has actually reached.
struct TransportCardMetrics {
    /// Standard transport button footprint. Also the unit the compact pill's width is counted in.
    static let buttonWidth: CGFloat = 44
    /// Play/pause is the primary control, so the expanded card gives it a wider hit area than its neighbours.
    static let expandedPlayWidth: CGFloat = 56
    /// Play/pause glyph sizes. The glyph is always drawn at the expanded size and scaled down for the pill: a
    /// `.font(size:)` change snaps between values, while a scale interpolates, and these two states have to morph into
    /// each other.
    static let expandedPlayGlyphSize: CGFloat = 34
    static let compactPlayGlyphSize: CGFloat = 20
    /// Spacing on each side of the centered prev / play / next triad in the expanded card — kept short so step-back and
    /// step-forward sit close to the play/pause button, equidistant from it. Matches VocalTuner's transport card. The
    /// compact pill closes it to zero, so its buttons sit shoulder to shoulder the way they always have.
    static let expandedTriadSpacing: CGFloat = 4
    /// Padding between the expanded card's edges and its content. The pill has none — its buttons *are* its width.
    static let expandedHorizontalPadding: CGFloat = 20
    static let expandedTopPadding: CGFloat = 6
    /// Margin between the seek card and the screen edges (leading / trailing / bottom). Kept small so the card hugs the
    /// edges; the bottom corner radius is derived from it so the card nests concentrically inside the device's rounded
    /// screen. Matches VocalTuner's `cardMargin`.
    static let cardMargin: CGFloat = 6
    /// Margin between the compact pill and the screen edge — wider than the card's, which nests into the device
    /// corners.
    static let compactMargin: CGFloat = 16
    /// Upper bound on the card width. On wide screens (iPad) the card stops growing and is centered instead of spanning
    /// the full width, keeping the seek bar within comfortable reach.
    static let maxCardWidth: CGFloat = 520
    /// Height of the compact pill: one transport button, no padding.
    static let collapsedHeight: CGFloat = 44

    /// 0 = compact pill, 1 = expanded seek card. Clamped, so a spring that overshoots can never invert a padding or
    /// drive a width past either end state.
    let morph: Double

    /// Room the control has to lay out in; 0 until it has been measured.
    private let availableWidth: CGFloat
    /// Transport buttons the pill has to hold: four, or five in a playlist (which adds next-score).
    private let buttonCount: CGFloat
    /// The expanded card's measured content height; `nil` until it has been laid out expanded once.
    private let measuredExpandedHeight: CGFloat?

    init(morph: Double, availableWidth: CGFloat, isInPlaylist: Bool, measuredExpandedHeight: CGFloat?) {
        self.morph = min(max(morph, 0), 1)
        self.availableWidth = availableWidth
        buttonCount = isInPlaylist ? 5 : 4
        self.measuredExpandedHeight = measuredExpandedHeight
    }

    /// Whether the card is all the way open. Used to decide when a measurement of the expanded content is trustworthy.
    var isFullyExpanded: Bool {
        morph >= 1
    }

    /// Whether the seek region belongs in the view tree at all. It goes in as soon as the card starts opening — and,
    /// crucially, comes back out the moment it is shut: kept mounted, its live playback fraction would re-render on
    /// every cursor tick behind a card that isn't showing it.
    var showsSeekRegion: Bool {
        morph > 0
    }

    var seekRegionOpacity: Double {
        morph
    }

    /// The two glass layers crossfade on this same scalar, and each is mounted only while it is visible at all —
    /// a settled card carries exactly one live glass effect, not a second fully transparent one that still samples
    /// the content behind it every frame.
    var showsExpandedGlass: Bool {
        morph > 0
    }

    var expandedGlassOpacity: Double {
        morph
    }

    var showsCompactGlass: Bool {
        morph < 1
    }

    var compactGlassOpacity: Double {
        1 - morph
    }

    /// Exactly its buttons edge to edge when shut, so the flexible side frames in the transport row collapse to nothing
    /// and the row hugs; that is what drains the expanded card's slack away as it closes.
    ///
    /// `nil` only while fully open and unmeasured — the card then takes the width it is offered, which is what the
    /// expanded layout wants anyway.
    var width: CGFloat? {
        guard availableWidth > 0 else { return isFullyExpanded ? nil : compactWidth }
        return lerp(compactWidth, expandedWidth)
    }

    /// A height that falls out of whatever content happens to be mounted has nothing to interpolate, so the card would
    /// jump by exactly the seek region's height the instant it is removed. The expanded figure is measured rather than
    /// assumed — a score with no rehearsal marks has no mark bar, and its card is genuinely shorter.
    var height: CGFloat? {
        guard let measuredExpandedHeight else { return isFullyExpanded ? nil : Self.collapsedHeight }
        return lerp(Self.collapsedHeight, measuredExpandedHeight)
    }

    /// Distance from the trailing edge to the card. Interpolating this — rather than flipping a `.frame` alignment from
    /// centered to trailing — is what lets the card *travel* toward the pill's corner as it shrinks: alignment is a
    /// discrete layout parameter with nothing in between, so switching it teleported the card.
    ///
    /// Fully open it works out to `cardMargin` on a phone (where the card spans the width) and to whatever centers the
    /// card once the screen is wider than `maxCardWidth` (iPad).
    var trailingInset: CGFloat {
        let expanded = availableWidth > 0
            ? max(Self.cardMargin, (availableWidth - expandedWidth) / 2)
            : Self.cardMargin
        return lerp(Self.compactMargin, expanded)
    }

    var horizontalPadding: CGFloat {
        lerp(0, Self.expandedHorizontalPadding)
    }

    var topPadding: CGFloat {
        lerp(0, Self.expandedTopPadding)
    }

    var triadSpacing: CGFloat {
        lerp(0, Self.expandedTriadSpacing)
    }

    var playWidth: CGFloat {
        lerp(Self.buttonWidth, Self.expandedPlayWidth)
    }

    var playGlyphScale: CGFloat {
        lerp(Self.compactPlayGlyphSize / Self.expandedPlayGlyphSize, 1)
    }

    /// Width of the clear spacer that balances the leading jump-back button outside a playlist. The expanded card needs
    /// it — an empty trailing group under `.frame(maxWidth: .infinity)` collapses to zero width, so the leading group
    /// would claim all the slack and shove the centered triad to the right — while the pill has no slack to fight over
    /// and no room for dead space, so it shrinks away with everything else.
    var trailingPlaceholderWidth: CGFloat {
        lerp(0, Self.buttonWidth)
    }

    private var compactWidth: CGFloat {
        buttonCount * Self.buttonWidth
    }

    private var expandedWidth: CGFloat {
        min(Self.maxCardWidth, availableWidth - 2 * Self.cardMargin)
    }

    private func lerp(_ compact: CGFloat, _ expanded: CGFloat) -> CGFloat {
        compact + (expanded - compact) * CGFloat(morph)
    }
}

/// Hands its content the *interpolated* value of `morph` on every frame of an animation, rather than the target the
/// view was rebuilt with.
///
/// This is the whole reason the card's resize survives a swipe: `Animatable` puts the interpolation on the animation
/// clock, where it is driven independently of — and cannot be overwritten by — the layout passes that the finger's
/// every movement triggers.
struct MorphReader<Content: View>: View, Animatable {
    var morph: Double
    private let content: (Double) -> Content

    init(morph: Double, @ViewBuilder content: @escaping (Double) -> Content) {
        self.morph = morph
        self.content = content
    }

    /// `nonisolated` because SwiftUI drives this from its animation machinery, off the main actor — a plain
    /// declaration makes the conformance cross into main-actor-isolated code and fails to compile under Swift 6.
    nonisolated var animatableData: Double {
        get { morph }
        set { morph = newValue }
    }

    var body: some View {
        content(morph)
    }
}
