import CoreGraphics
import Foundation
import SwiftUI

/// Result of a horizontal swipe over the transport control: right hides the seek bar, left brings it back, and
/// anything too short or too vertical leaves the current mode alone.
enum TransportModeSwipeOutcome: Equatable {
    /// Swipe right — drop the expanded seek card for the compact pill.
    case collapse
    /// Swipe left — bring the expanded seek card back.
    case expand
    /// Not a mode swipe; leave the transport as it is.
    case ignore
}

/// Pure geometry for the transport's swipe-to-switch-mode gesture: the commit decision, the rubber band the control
/// rides while the finger is down, and the spring that settles it on release. Kept out of the view so the thresholds
/// are testable — the same split as `PagedReaderNavigation` for the page-turn swipe.
///
/// The feel is modelled on the editing pad's re-dock drag (`EditorChromeView`): the control tracks the finger, leans
/// against a rubber band where there is nothing to switch to, and springs back with the velocity it was released at.
enum TransportModeSwipe {
    /// Horizontal travel that commits a mode change. Roughly the width of one transport button, so the swipe reads as
    /// deliberate but never needs a full sweep across the card.
    static let commitDistance: CGFloat = 44

    /// How far the control can travel toward the mode the swipe would switch to. Well past `commitDistance`, so the
    /// band is barely felt until the swipe has already committed — but finite, so a long sweep can never drag the card
    /// off the screen.
    static let followLimit: CGFloat = 120

    /// How far the control can travel the other way. There is no third mode in that direction, so the control leans a
    /// few points to stay under the finger and no further — the same "this axis isn't a destination" lean the editing
    /// pad has sideways.
    static let leanLimit: CGFloat = 20

    /// Given a finished drag's translation and its fling projection, decide which transport mode the release asks
    /// for.
    ///
    /// Rules:
    /// - A drag that travels further vertically than horizontally is a vertical flick over the transport (or the
    ///   start of a two-finger score gesture), not a mode swipe.
    /// - Commit on `commitDistance` of actual travel; below that, fall back to the predicted end so a fast, short
    ///   flick still switches modes.
    static func outcome(
        translation: CGSize,
        predictedEndTranslation: CGSize,
    ) -> TransportModeSwipeOutcome {
        guard abs(translation.width) >= abs(translation.height) else { return .ignore }

        let travel = abs(translation.width) >= commitDistance
            ? translation.width
            : predictedEndTranslation.width
        guard abs(travel) >= commitDistance else { return .ignore }

        return travel < 0 ? .expand : .collapse
    }

    /// The offset the control renders for a live finger travel of `translation`, given the mode it is currently in.
    ///
    /// Toward the other mode the control is **glued to the finger for the whole commit distance** and only then eases
    /// onto its asymptote. A single `tanh` over the whole range starts resisting almost immediately, and a quick swipe
    /// — which covers a lot of ground fast — left the card visibly trailing the finger: it read as the card catching
    /// on something. Nobody drags past `commitDistance` expecting 1:1 tracking to continue forever, but everybody
    /// expects it up to the point where the swipe means something.
    ///
    /// Away from the other mode there is nothing to reach, so a much stiffer band lets the control lean a few points
    /// and no further.
    static func followOffset(translation: CGFloat, isExpanded: Bool) -> CGFloat {
        // Expanded collapses on a right swipe; compact expands on a left one.
        let towardOtherMode = isExpanded ? translation > 0 : translation < 0
        let sign: CGFloat = translation < 0 ? -1 : 1
        let travel = abs(translation)

        guard towardOtherMode else {
            return sign * leanLimit * CGFloat(tanh(Double(travel / leanLimit)))
        }
        guard travel > commitDistance else { return translation }
        // `tanh` gives the band for free past that point: linear where it takes over from the 1:1 stretch, then
        // flattening onto the asymptote, so the control can never wander further than `followLimit`.
        let give = followLimit - commitDistance
        let beyond = give * CGFloat(tanh(Double((travel - commitDistance) / give)))
        return sign * (commitDistance + beyond)
    }

    /// The settle animation that carries a released control back to zero offset.
    ///
    /// Paced by the same `flickness` as the card's resize, so the two halves of the gesture finish together. They used
    /// to disagree — the offset was timed off its travel distance alone, so a flick left the card sliding home while
    /// the morph was still going (or the reverse), and the mismatch read as the control snagging.
    ///
    /// `bounce: 0` (critically damped) is deliberate: the transport is a slab of controls settling back against the
    /// bottom edge, and overshoot reads as wobble.
    static func releaseAnimation(from offset: CGFloat, releaseVelocity: CGFloat) -> Animation {
        .interpolatingSpring(
            duration: settleDuration(swipeSpeed: releaseVelocity), bounce: 0,
            initialVelocity: settleVelocity(releaseVelocity, travel: -offset),
        )
    }

    /// A spring's initial velocity is expressed in fractions of the REMAINING DISTANCE per second, so raw pt/s has to
    /// be divided by that distance. The dead band keeps a gentle release (which is a release, not a throw) from being
    /// catapulted by what little travel is left.
    ///
    /// A finger still moving *outward* at release yields a velocity pointing away from the settle, and it is KEPT
    /// (clamped to a gentle -1, the editing pad's bound): the control then coasts a touch further before turning
    /// round, which is what momentum looks like. An earlier iteration zeroed it instead — blaming the overshoot for
    /// a release hitch whose real cause was the synchronous score re-layout the preference write used to trigger on
    /// the same frame — and the resulting one-frame stop from full flick speed to zero is precisely what a paused
    /// screen recording shows as the control "catching" at the moment the finger lifts.
    static func settleVelocity(_ velocity: CGFloat, travel: CGFloat) -> CGFloat {
        let deadBand: CGFloat = 80 // pt/s
        guard abs(travel) >= 1, abs(velocity) > deadBand else { return 0 }
        return min(3, max(-1, velocity / travel))
    }

    /// How long the owner should sit on the persisted-preference write after taking a committed swipe. Writing
    /// `showSeekBar` immediately shrinks or grows the room `ReaderRootScreen` reserves for the score
    /// (`bottomControlContentHeight`, 110 ⇄ 44), and in page mode that re-paginates the score — heavy enough to eat
    /// the first frames of the settle spring and the card morph, which read as the control snagging right as the
    /// finger lifts. Longer than the slowest of either release animation (`slowModeSwapDuration`,
    /// `slowSettleDuration`), so the reflow only lands once the transport has visually come to rest; the control
    /// holds the committed mode locally (`previewSeekBar`) until the write catches up, so nothing on screen depends
    /// on it landing promptly.
    static let preferenceCommitDelay = 0.45

    /// How long the acted-out swipe takes to travel out to `commitDistance` before the release spring brings it back
    /// (see `ReaderTransportControl.performHintedModeSwitch`). Short enough to read as one continuous motion with the
    /// morph, long enough that the direction registers.
    static let hintedSwipeOutDuration = 0.16

    /// Slowest swipe that still counts as deliberate, and the speed from which everything is as quick as it gets.
    static let deliberateSwipeSpeed: CGFloat = 200 // pt/s
    static let flickSwipeSpeed: CGFloat = 2000 // pt/s

    /// Card-resize duration at either end of that speed range.
    static let slowModeSwapDuration = 0.35
    static let fastModeSwapDuration = 0.22
    /// Offset-settle duration at either end. Deliberately a touch shorter than the resize at both ends: the offset has
    /// a short distance to cover and looks sluggish if it lingers once the card has stopped changing shape.
    static let slowSettleDuration = 0.30
    static let fastSettleDuration = 0.16

    /// How much of a flick a swipe was: 0 for a deliberate drag, 1 from `flickSwipeSpeed` upward. Direction-blind —
    /// a left swipe is exactly as fast as the right one that mirrors it.
    static func flickness(swipeSpeed: CGFloat) -> Double {
        let speed = min(max(abs(swipeSpeed), deliberateSwipeSpeed), flickSwipeSpeed)
        return Double((speed - deliberateSwipeSpeed) / (flickSwipeSpeed - deliberateSwipeSpeed))
    }

    /// How long the card should take to resize, given how fast the finger was moving when the mode flipped.
    static func modeSwapDuration(swipeSpeed: CGFloat) -> Double {
        paced(slowModeSwapDuration, fastModeSwapDuration, swipeSpeed: swipeSpeed)
    }

    /// How long the released control should take to slide back to zero offset.
    static func settleDuration(swipeSpeed: CGFloat) -> Double {
        paced(slowSettleDuration, fastSettleDuration, swipeSpeed: swipeSpeed)
    }

    private static func paced(_ slow: Double, _ fast: Double, swipeSpeed: CGFloat) -> Double {
        slow + (fast - slow) * flickness(swipeSpeed: swipeSpeed)
    }

    /// The mode swap itself — the card resizing between the seek card and the pill, paced by `swipeSpeed` (the
    /// finger's speed at the moment the mode flipped, or at release for a flick that commits without ever crossing
    /// the threshold), so the resize keeps up with the swipe that asked for it.
    ///
    /// This has to be handed to an explicit `withAnimation` at the point the mode flips, NOT attached as an
    /// `.animation(_:value:)` on the control: the flip happens inside the swipe's `onChanged`, and SwiftUI marks
    /// gesture-driven updates as *continuous* transactions, where implicit animation modifiers are ignored. Attached
    /// implicitly, the card jumped between sizes in a single frame (confirmed frame-by-frame on device) — the mode was
    /// changing correctly, it simply was not being animated.
    static func modeSwapAnimation(swipeSpeed: CGFloat) -> Animation {
        .snappy(duration: modeSwapDuration(swipeSpeed: swipeSpeed), extraBounce: 0)
    }
}

extension View {
    /// Makes a transport row (or the compact pill) swipeable to switch modes.
    ///
    /// `contentShape` extends the swipe to the gaps between the buttons, so the whole row — not just the glyphs —
    /// takes the drag. `highPriorityGesture` is what lets the drag coexist with those buttons: a tap never travels
    /// the gesture's minimum distance, so the button underneath gets it; once the finger does travel, the drag wins
    /// outright and the button it started on is cancelled rather than fired on release (the editing pad's trick).
    func transportModeSwipe(_ gesture: some Gesture) -> some View {
        contentShape(Rectangle())
            .highPriorityGesture(gesture)
    }
}
