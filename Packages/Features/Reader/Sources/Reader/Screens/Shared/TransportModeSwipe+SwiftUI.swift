import ReaderInteractionCore
import SwiftUI

/// SwiftUI's half of the transport's mode swipe. Every number behind these — the commit distance, the rubber band,
/// how a flick paces the resize — lives in `ReaderInteractionCore.TransportModeSwipe`, which Android's Compose
/// transport reads the same values out of. What stays here is only what cannot cross: `Animation` values and the
/// gesture attachment.
extension TransportModeSwipe {
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

    /// `outcome` stated in the `CGSize` values a `DragGesture` hands out. The engine takes scalars so its signature
    /// survives the JNI boundary; this is the call every SwiftUI site actually wants.
    static func outcome(translation: CGSize, predictedEndTranslation: CGSize) -> TransportModeSwipeOutcome {
        outcome(
            translationX: translation.width,
            translationY: translation.height,
            predictedEndTranslationX: predictedEndTranslation.width,
        )
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
