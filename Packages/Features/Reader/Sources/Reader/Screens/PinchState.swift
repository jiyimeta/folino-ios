import CoreGraphics
import QuartzCore
import SwiftUI

/// Live, gesture-driven pinch state shared by `VerticalScoreContainer` and `HorizontalScoreContainer`.
///
/// Kept as an `@Observable` reference (not individual `@State` on the container) so SwiftUI's observation system
/// delivers mutations straight to the hosted score subtree. That matters because `ScoreScrollHost` is a
/// `UIViewRepresentable` wrapping a `UIHostingController`, and a `withAnimation { … }` at the call site does *not*
/// propagate through the host's `rootView` reassignment — the inner SwiftUI render sees a fresh tree with no
/// transaction. Driving the values through observation instead avoids the bridge entirely: the hosted subtree
/// re-renders inside the animation transaction the mutation was made under, so `scaleEffect` / `offset` / `frame`
/// interpolate as expected.
///
/// The container owns the instance via `@State`, so the same observable lives for the view's lifetime; only its
/// properties change.
@Observable
@MainActor
final class PinchState {
    /// Inner scaleEffect factor, pivoted at `anchor`. Set every `.changed` tick to `UIPinchGestureRecognizer.scale`
    /// (1.0 at gesture start) and reset to 1.0 at commit time.
    var magnification: CGFloat = 1.0
    /// Inner scaleEffect anchor in the hosted content's unit space. Captured once at `.began` so the visual pivot stays
    /// under the user's fingers for the duration of the gesture.
    var anchor: UnitPoint = .center
    /// Horizontal pan-during-pinch offset. Used by `VerticalScoreContainer` (where the UIScrollView has no horizontal
    /// scrollable extent at user-zoom 1.0). Horizontal mode reads this but writes nothing — its X axis pans via the
    /// scroll view's native `contentOffset`.
    var offsetX: CGFloat = 0
    /// Vertical pan-during-pinch offset. Mirror of `offsetX`, used by `HorizontalScoreContainer` (where the
    /// UIScrollView has no vertical scrollable extent at user-zoom 1.0).
    var offsetY: CGFloat = 0

    // MARK: Commit reset animation (manual, frame-by-frame)

    // The pinch commit eases `magnification` / `offsetX` back to their resting values. We do this by interpolating the
    // STORED values frame-by-frame (CADisplayLink) instead of `withAnimation`, because the annotation ink is a UIKit
    // PKCanvasView overlay that mirrors these values each frame: a `withAnimation` transaction jumps the stored value
    // to its target immediately (SwiftUI interpolates only the rendered transform), so the overlay — reading the
    // already-jumped value — would snap ahead and momentarily separate from the score. With manual interpolation the
    // score (via observation) and the ink (via its sync) read the same per-frame value, so they stay registered.

    @ObservationIgnored private var resetLink: CADisplayLink?
    @ObservationIgnored private var resetStart: CFTimeInterval = 0
    @ObservationIgnored private var resetDuration: CFTimeInterval = 0.18
    @ObservationIgnored private var fromMagnification: CGFloat = 1
    @ObservationIgnored private var toMagnification: CGFloat = 1
    @ObservationIgnored private var fromOffsetX: CGFloat = 0
    @ObservationIgnored private var toOffsetX: CGFloat = 0

    /// Stop any in-flight reset (call at gesture `.began` so a fresh pinch isn't fought by a trailing animation).
    func cancelResetAnimation() {
        resetLink?.invalidate()
        resetLink = nil
    }

    /// Ease `magnification` and `offsetX` to the given targets over `duration`, mutating the stored values each frame.
    func animateReset(toMagnification mag: CGFloat, offsetX targetOffsetX: CGFloat, duration: CFTimeInterval = 0.18) {
        cancelResetAnimation()
        fromMagnification = magnification
        toMagnification = mag
        fromOffsetX = offsetX
        toOffsetX = targetOffsetX
        resetStart = CACurrentMediaTime()
        resetDuration = max(0.0001, duration)
        let link = CADisplayLink(target: self, selector: #selector(stepResetAnimation))
        link.add(to: .main, forMode: .common)
        resetLink = link
    }

    @objc private func stepResetAnimation() {
        let t = min(1, (CACurrentMediaTime() - resetStart) / resetDuration)
        let eased = 1 - pow(1 - t, 3) // easeOutCubic — visually close to SwiftUI's `.smooth`
        magnification = fromMagnification + (toMagnification - fromMagnification) * CGFloat(eased)
        offsetX = fromOffsetX + (toOffsetX - fromOffsetX) * CGFloat(eased)
        if t >= 1 {
            magnification = toMagnification
            offsetX = toOffsetX
            cancelResetAnimation()
        }
    }
}
