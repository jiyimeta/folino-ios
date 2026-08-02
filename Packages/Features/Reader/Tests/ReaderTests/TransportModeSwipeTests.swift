import CoreGraphics
@testable import Reader
import Testing

struct TransportModeSwipeTests {
    @Test func `right swipe collapses to the compact pill`() {
        let outcome = TransportModeSwipe.outcome(
            translation: CGSize(width: 60, height: 4),
            predictedEndTranslation: CGSize(width: 60, height: 4),
        )
        #expect(outcome == .collapse)
    }

    @Test func `left swipe expands the seek card`() {
        let outcome = TransportModeSwipe.outcome(
            translation: CGSize(width: -60, height: -4),
            predictedEndTranslation: CGSize(width: -60, height: -4),
        )
        #expect(outcome == .expand)
    }

    @Test func `short drag is ignored`() {
        let outcome = TransportModeSwipe.outcome(
            translation: CGSize(width: 20, height: 2),
            predictedEndTranslation: CGSize(width: 22, height: 2),
        )
        #expect(outcome == .ignore)
    }

    @Test func `fast flick commits even when the drag itself is short`() {
        let outcome = TransportModeSwipe.outcome(
            translation: CGSize(width: -18, height: 3),
            predictedEndTranslation: CGSize(width: -220, height: 8),
        )
        #expect(outcome == .expand)
    }

    @Test func `mostly vertical drag is ignored`() {
        let outcome = TransportModeSwipe.outcome(
            translation: CGSize(width: 50, height: 120),
            predictedEndTranslation: CGSize(width: 60, height: 200),
        )
        #expect(outcome == .ignore)
    }

    @Test func `a drag that goes nowhere is ignored`() {
        let outcome = TransportModeSwipe.outcome(
            translation: .zero,
            predictedEndTranslation: .zero,
        )
        #expect(outcome == .ignore)
    }

    @Test func `the card is glued to the finger for the whole commit distance`() {
        #expect(TransportModeSwipe.followOffset(translation: 20, isExpanded: true) == 20)
        #expect(
            TransportModeSwipe.followOffset(
                translation: TransportModeSwipe.commitDistance,
                isExpanded: true,
            ) == TransportModeSwipe.commitDistance,
        )
        // The compact pill's own direction is mirrored, sign and all.
        #expect(TransportModeSwipe.followOffset(translation: -20, isExpanded: false) == -20)
    }

    @Test func `past the commit distance the band takes over smoothly`() {
        let atCommit = TransportModeSwipe.followOffset(translation: 44, isExpanded: true)
        let justPast = TransportModeSwipe.followOffset(translation: 54, isExpanded: true)
        #expect(justPast > atCommit)
        // Eased, so ten more points of finger buy less than ten points of card.
        #expect(justPast < atCommit + 10)
    }

    @Test func `travel toward the other mode is capped at the follow limit`() {
        // `tanh` saturates for a sweep this long, so the asymptote is reached exactly rather than approached.
        let offset = TransportModeSwipe.followOffset(translation: 2000, isExpanded: true)
        #expect(offset <= TransportModeSwipe.followLimit)
        #expect(offset > TransportModeSwipe.followLimit - 1)
    }

    @Test func `travel away from the other mode only leans`() {
        let offset = TransportModeSwipe.followOffset(translation: -2000, isExpanded: true)
        #expect(offset < 0)
        #expect(abs(offset) <= TransportModeSwipe.leanLimit)
    }

    @Test func `the compact pill mirrors the directions`() {
        let towardExpanded = TransportModeSwipe.followOffset(translation: -2000, isExpanded: false)
        #expect(towardExpanded < 0)
        #expect(abs(towardExpanded) > TransportModeSwipe.leanLimit)
        #expect(abs(towardExpanded) <= TransportModeSwipe.followLimit)

        let away = TransportModeSwipe.followOffset(translation: 2000, isExpanded: false)
        #expect(away <= TransportModeSwipe.leanLimit)
    }

    @Test func `no travel means no offset`() {
        #expect(TransportModeSwipe.followOffset(translation: 0, isExpanded: true) == 0)
        #expect(TransportModeSwipe.followOffset(translation: 0, isExpanded: false) == 0)
    }

    @Test func `the settle is paced by the same flickness as the resize`() {
        let flick = TransportModeSwipe.settleDuration(swipeSpeed: TransportModeSwipe.flickSwipeSpeed)
        let deliberate = TransportModeSwipe.settleDuration(swipeSpeed: TransportModeSwipe.deliberateSwipeSpeed)
        #expect(isClose(flick, TransportModeSwipe.fastSettleDuration))
        #expect(isClose(deliberate, TransportModeSwipe.slowSettleDuration))
        // Never left lingering after the card has stopped changing shape.
        #expect(flick < TransportModeSwipe.modeSwapDuration(swipeSpeed: TransportModeSwipe.flickSwipeSpeed))
        #expect(deliberate < TransportModeSwipe.modeSwapDuration(swipeSpeed: TransportModeSwipe.deliberateSwipeSpeed))
    }

    @Test func `flickness spans nothing to everything across the speed range`() {
        #expect(TransportModeSwipe.flickness(swipeSpeed: 0) == 0)
        #expect(TransportModeSwipe.flickness(swipeSpeed: TransportModeSwipe.deliberateSwipeSpeed) == 0)
        #expect(TransportModeSwipe.flickness(swipeSpeed: TransportModeSwipe.flickSwipeSpeed) == 1)
        #expect(TransportModeSwipe.flickness(swipeSpeed: 9000) == 1)
        #expect(TransportModeSwipe.flickness(swipeSpeed: -9000) == 1)
    }

    /// The duration is interpolated, so the ends land a rounding error away from the constants they are built from.
    private func isClose(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 1e-9
    }

    @Test func `a flick resizes the card faster than a deliberate drag`() {
        let flick = TransportModeSwipe.modeSwapDuration(swipeSpeed: TransportModeSwipe.flickSwipeSpeed)
        let deliberate = TransportModeSwipe.modeSwapDuration(swipeSpeed: TransportModeSwipe.deliberateSwipeSpeed)
        #expect(isClose(flick, TransportModeSwipe.fastModeSwapDuration))
        #expect(isClose(deliberate, TransportModeSwipe.slowModeSwapDuration))
        #expect(flick < deliberate)
    }

    @Test func `morph duration is clamped outside the speed range and reads direction-blind`() {
        #expect(isClose(
            TransportModeSwipe.modeSwapDuration(swipeSpeed: 6000),
            TransportModeSwipe.fastModeSwapDuration,
        ))
        #expect(isClose(
            TransportModeSwipe.modeSwapDuration(swipeSpeed: 0),
            TransportModeSwipe.slowModeSwapDuration,
        ))
        // A left swipe is just as fast as the right one that mirrors it.
        #expect(
            TransportModeSwipe.modeSwapDuration(swipeSpeed: -900)
                == TransportModeSwipe.modeSwapDuration(swipeSpeed: 900),
        )
    }

    @Test func `morph duration falls off monotonically with speed`() {
        let durations = stride(from: CGFloat(0), through: 2400, by: 200)
            .map { TransportModeSwipe.modeSwapDuration(swipeSpeed: $0) }
        #expect(zip(durations, durations.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test func `a finger still travelling outward keeps a gently clamped outward velocity`() {
        // Released mid-flick to the right: the offset is positive, so the settle travels negative and the finger's
        // outward speed maps to a negative spring velocity. It is kept — clamped to -1 — so the control coasts a
        // touch further before turning round instead of stopping dead in a single frame, which is what read as the
        // control snagging at the lift.
        #expect(TransportModeSwipe.settleVelocity(1800, travel: -100) == -1)
    }

    @Test func `the preference write is held past the slowest release animation`() {
        // The owner defers the persisted-preference write by this long so the score reflow it triggers lands after
        // the settle spring and the card morph have finished (see `ReaderRootScreen.setSeekBarVisible`).
        #expect(TransportModeSwipe.preferenceCommitDelay > TransportModeSwipe.slowModeSwapDuration)
        #expect(TransportModeSwipe.preferenceCommitDelay > TransportModeSwipe.slowSettleDuration)
    }

    @Test func `a finger already coming back keeps its speed`() {
        let velocity = TransportModeSwipe.settleVelocity(-300, travel: -100)
        #expect(velocity == 3)
    }

    @Test func `a gentle release is a release, not a throw`() {
        #expect(TransportModeSwipe.settleVelocity(-40, travel: -100) == 0)
        #expect(TransportModeSwipe.settleVelocity(-300, travel: 0) == 0)
    }

    @Test func `commit distance is the exact boundary`() {
        let commit = TransportModeSwipe.outcome(
            translation: CGSize(width: TransportModeSwipe.commitDistance, height: 0),
            predictedEndTranslation: CGSize(width: TransportModeSwipe.commitDistance, height: 0),
        )
        #expect(commit == .collapse)

        let justUnder = TransportModeSwipe.outcome(
            translation: CGSize(width: TransportModeSwipe.commitDistance - 1, height: 0),
            predictedEndTranslation: CGSize(width: TransportModeSwipe.commitDistance - 1, height: 0),
        )
        #expect(justUnder == .ignore)
    }
}
