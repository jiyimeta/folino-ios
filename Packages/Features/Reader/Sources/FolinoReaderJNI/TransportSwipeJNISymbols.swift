import ReaderInteractionCore

// swift-java (jextract) entry points for the Android transport's swipe-to-resize gesture. Pure delegation to the
// shared `ReaderInteractionCore.TransportModeSwipe`, which iOS's `ReaderTransportControl` calls too, so the two
// platforms commit on the same travel, rubber-band along the same curve and pace their animations off the same
// speeds (parity — no divergent Kotlin port). Compose knows only how to draw the result.
//
// Durations cross as milliseconds because that is what Compose's animation specs take: doing the conversion here
// means the rounding happens once, in shared code, rather than once per call site on each platform.

/// Which mode a finished (or in-flight) drag asks for: 0 collapse, 1 expand, 2 ignore —
/// `TransportModeSwipeOutcome.rawValue`.
///
/// Pass `predictedEndTranslationX == translationX` while the finger is still down: a live preview should follow the
/// finger rather than guess where it is headed.
public func nativeTransportSwipeOutcome(
    translationX: Double,
    translationY: Double,
    predictedEndTranslationX: Double,
) -> Int32 {
    TransportModeSwipe.outcome(
        translationX: translationX,
        translationY: translationY,
        predictedEndTranslationX: predictedEndTranslationX,
    ).rawValue
}

/// The offset the control renders for a live finger travel, rubber-banded against the mode it is in.
public func nativeTransportFollowOffset(translation: Double, isExpanded: Bool) -> Double {
    TransportModeSwipe.followOffset(translation: translation, isExpanded: isExpanded)
}

/// The spring's initial velocity as a fraction of the remaining distance per second — see
/// `TransportModeSwipe.settleVelocity`.
public func nativeTransportSettleVelocity(velocity: Double, travel: Double) -> Double {
    TransportModeSwipe.settleVelocity(velocity, travel: travel)
}

/// How long the card should take to change size, given the finger's speed when the mode flipped.
public func nativeTransportModeSwapDurationMillis(swipeSpeed: Double) -> Int32 {
    Int32((TransportModeSwipe.modeSwapDuration(swipeSpeed: swipeSpeed) * 1000).rounded())
}

/// How long the released control should take to slide back to zero offset.
public func nativeTransportSettleDurationMillis(swipeSpeed: Double) -> Int32 {
    Int32((TransportModeSwipe.settleDuration(swipeSpeed: swipeSpeed) * 1000).rounded())
}

/// Horizontal travel that commits a mode change — also how far the coach mark's acted-out swipe travels.
public func nativeTransportCommitDistance() -> Double {
    TransportModeSwipe.commitDistance
}

/// How long the owner must sit on the persisted-preference write after taking a committed swipe, so the score's
/// re-layout lands after the transport has come to rest rather than during it.
public func nativeTransportPreferenceCommitDelayMillis() -> Int32 {
    Int32((TransportModeSwipe.preferenceCommitDelay * 1000).rounded())
}

/// How long the acted-out swipe travels out before the release animation brings it home.
public func nativeTransportHintedSwipeOutMillis() -> Int32 {
    Int32((TransportModeSwipe.hintedSwipeOutDuration * 1000).rounded())
}
