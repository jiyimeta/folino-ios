import Foundation

/// Result of a horizontal swipe over the transport control: right hides the seek bar, left brings it back, and
/// anything too short or too vertical leaves the current mode alone.
///
/// `Int32`-backed so the Android bridge can carry it over the JNI boundary as a plain scalar — the wire codegen has
/// no `Int`, and an enum that crosses it has to name its own numbers rather than let the compiler pick them.
public enum TransportModeSwipeOutcome: Int32, Equatable, Sendable {
    /// Swipe right — drop the expanded seek card for the compact pill.
    case collapse = 0
    /// Swipe left — bring the expanded seek card back.
    case expand = 1
    /// Not a mode swipe; leave the transport as it is.
    case ignore = 2
}

/// Pure geometry for the transport's swipe-to-switch-mode gesture: the commit decision, the rubber band the control
/// rides while the finger is down, and the pacing of the animations that settle it on release.
///
/// Platform-neutral on purpose. Both readers ship this gesture, and every number in it is a feel decision that has to
/// be the same on both — a 44 pt commit on one platform and a 48 dp commit on the other is a divergence nobody would
/// ever notice in review and every user would feel. iOS builds SwiftUI `Animation`s out of the durations below
/// (`TransportModeSwipe+Animation.swift` in the `Reader` target); Compose builds its `tween`/`spring` specs out of
/// the same ones. Neither owns them.
///
/// Distances are in **points on iOS and density-independent pixels on Android**, which are the same physical size by
/// construction; speeds are the same units per second. `Double` rather than `CGFloat` because Android's Foundation
/// ships its own `CGFloat` that silently shadows any stub with that name — see the Android drift notes.
///
/// The feel is modelled on the editing pad's re-dock drag (`EditorChromeView`): the control tracks the finger, leans
/// against a rubber band where there is nothing to switch to, and springs back with the velocity it was released at.
public enum TransportModeSwipe {
    /// Horizontal travel that commits a mode change. Roughly the width of one transport button, so the swipe reads as
    /// deliberate but never needs a full sweep across the card.
    public static let commitDistance: Double = 44

    /// How far the control can travel toward the mode the swipe would switch to. Well past `commitDistance`, so the
    /// band is barely felt until the swipe has already committed — but finite, so a long sweep can never drag the card
    /// off the screen.
    public static let followLimit: Double = 120

    /// How far the control can travel the other way. There is no third mode in that direction, so the control leans a
    /// few points to stay under the finger and no further — the same "this axis isn't a destination" lean the editing
    /// pad has sideways.
    public static let leanLimit: Double = 20

    /// Given a finished drag's translation and its fling projection, decide which transport mode the release asks
    /// for.
    ///
    /// Rules:
    /// - A drag that travels further vertically than horizontally is a vertical flick over the transport (or the
    ///   start of a two-finger score gesture), not a mode swipe.
    /// - Commit on `commitDistance` of actual travel; below that, fall back to the predicted end so a fast, short
    ///   flick still switches modes.
    ///
    /// Taken as four scalars rather than two size values so the signature survives the JNI boundary unchanged.
    public static func outcome(
        translationX: Double,
        translationY: Double,
        predictedEndTranslationX: Double,
    ) -> TransportModeSwipeOutcome {
        guard abs(translationX) >= abs(translationY) else { return .ignore }

        let travel = abs(translationX) >= commitDistance ? translationX : predictedEndTranslationX
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
    public static func followOffset(translation: Double, isExpanded: Bool) -> Double {
        // Expanded collapses on a right swipe; compact expands on a left one.
        let towardOtherMode = isExpanded ? translation > 0 : translation < 0
        let sign: Double = translation < 0 ? -1 : 1
        let travel = abs(translation)

        guard towardOtherMode else {
            return sign * leanLimit * tanh(travel / leanLimit)
        }
        guard travel > commitDistance else { return translation }
        // `tanh` gives the band for free past that point: linear where it takes over from the 1:1 stretch, then
        // flattening onto the asymptote, so the control can never wander further than `followLimit`.
        let give = followLimit - commitDistance
        let beyond = give * tanh((travel - commitDistance) / give)
        return sign * (commitDistance + beyond)
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
    public static func settleVelocity(_ velocity: Double, travel: Double) -> Double {
        let deadBand: Double = 80 // pt/s
        guard abs(travel) >= 1, abs(velocity) > deadBand else { return 0 }
        return min(3, max(-1, velocity / travel))
    }

    /// How long the owner should sit on the persisted-preference write after taking a committed swipe. Writing
    /// `showSeekBar` immediately shrinks or grows the room the Reader reserves for the score (110 ⇄ 44), and in page
    /// mode that re-paginates the score — heavy enough to eat the first frames of the settle spring and the card
    /// morph, which read as the control snagging right as the finger lifts. Longer than the slowest of either release
    /// animation (`slowModeSwapDuration`, `slowSettleDuration`), so the reflow only lands once the transport has
    /// visually come to rest; the control holds the committed mode locally until the write catches up, so nothing on
    /// screen depends on it landing promptly.
    public static let preferenceCommitDelay = 0.45

    /// How long the acted-out swipe takes to travel out to `commitDistance` before the release spring brings it back
    /// (the coach mark teaches the gesture by performing it). Short enough to read as one continuous motion with the
    /// morph, long enough that the direction registers.
    public static let hintedSwipeOutDuration = 0.16

    /// Slowest swipe that still counts as deliberate, and the speed from which everything is as quick as it gets.
    public static let deliberateSwipeSpeed: Double = 200 // pt/s
    public static let flickSwipeSpeed: Double = 2000 // pt/s

    /// Card-resize duration at either end of that speed range.
    public static let slowModeSwapDuration = 0.35
    public static let fastModeSwapDuration = 0.22
    /// Offset-settle duration at either end. Deliberately a touch shorter than the resize at both ends: the offset has
    /// a short distance to cover and looks sluggish if it lingers once the card has stopped changing shape.
    public static let slowSettleDuration = 0.30
    public static let fastSettleDuration = 0.16

    /// How much of a flick a swipe was: 0 for a deliberate drag, 1 from `flickSwipeSpeed` upward. Direction-blind —
    /// a left swipe is exactly as fast as the right one that mirrors it.
    public static func flickness(swipeSpeed: Double) -> Double {
        let speed = min(max(abs(swipeSpeed), deliberateSwipeSpeed), flickSwipeSpeed)
        return (speed - deliberateSwipeSpeed) / (flickSwipeSpeed - deliberateSwipeSpeed)
    }

    /// How long the card should take to resize, given how fast the finger was moving when the mode flipped.
    public static func modeSwapDuration(swipeSpeed: Double) -> Double {
        paced(slowModeSwapDuration, fastModeSwapDuration, swipeSpeed: swipeSpeed)
    }

    /// How long the released control should take to slide back to zero offset.
    public static func settleDuration(swipeSpeed: Double) -> Double {
        paced(slowSettleDuration, fastSettleDuration, swipeSpeed: swipeSpeed)
    }

    private static func paced(_ slow: Double, _ fast: Double, swipeSpeed: Double) -> Double {
        slow + (fast - slow) * flickness(swipeSpeed: swipeSpeed)
    }
}
