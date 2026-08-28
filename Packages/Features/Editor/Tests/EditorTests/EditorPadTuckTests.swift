@testable import Editor
import SwiftUI
import Testing

@Suite("EditorPadTuckGeometry")
struct EditorPadTuckTests {
    /// iPhone 16 Pro portrait-ish viewport.
    private let viewport = CGSize(width: 402, height: 874)
    private var threshold: CGFloat {
        EditorPadTuckGeometry.threshold(in: viewport)
    }

    @Test func `threshold is a fifth of the short side`() {
        #expect(threshold == 402 * 0.2)
        // Rotating the same screen must not change the felt distance.
        let landscape = CGSize(width: 874, height: 402)
        #expect(EditorPadTuckGeometry.threshold(in: landscape) == threshold)
    }

    @Test func `rest offset parks the pad's card just past the edge`() {
        let padWidth: CGFloat = 380
        let margin: CGFloat = 12
        let trailing = EditorPadTuckGeometry.restOffsetX(
            side: .trailing, viewportWidth: 402, padWidth: padWidth, margin: margin,
        )
        // Centered rest puts the frame's leading edge at (W - p) / 2 and the CARD's at margin further in; the
        // offset must carry the card's edge to exactly W.
        #expect((402 - padWidth) / 2 + margin + trailing == 402)
        let leading = EditorPadTuckGeometry.restOffsetX(
            side: .leading, viewportWidth: 402, padWidth: padWidth, margin: margin,
        )
        // Mirror image: the card's trailing edge lands at 0.
        #expect((402 + padWidth) / 2 - margin + leading == 0)
    }

    /// A release velocity pointing more sideways than vertically — the quick short hide-flick's shape.
    private let sidewaysFlick = CGSize(width: 900, height: 200)

    @Test func `short drag repositions instead of tucking`() {
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: threshold - 1, projectedTranslationX: threshold - 1,
            velocity: sidewaysFlick, threshold: threshold,
        ) == nil)
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: 1 - threshold, projectedTranslationX: 1 - threshold,
            velocity: sidewaysFlick, threshold: threshold,
        ) == nil)
    }

    @Test func `outward drag past threshold tucks toward the drag direction`() {
        // The finger actually covered the distance — velocity direction doesn't matter (the diagonal corner throw).
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: threshold, projectedTranslationX: threshold,
            velocity: CGSize(width: 300, height: -1200), threshold: threshold,
        ) == .trailing)
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: -threshold, projectedTranslationX: -threshold,
            velocity: CGSize(width: -300, height: -1200), threshold: threshold,
        ) == .leading)
    }

    @Test func `a quick sideways flick tucks on projection alone`() {
        // Short actual travel, but the release velocity points sideways: the deliberate hide-flick.
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: threshold / 3, projectedTranslationX: threshold + 50,
            velocity: sidewaysFlick, threshold: threshold,
        ) == .trailing)
    }

    @Test func `a fast vertical dock flick with sideways drift does not tuck`() {
        // The projection clears the threshold only because the flick was fast; the finger barely moved sideways and
        // the velocity points up — this is a dock move, not a dismissal.
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: 25, projectedTranslationX: threshold + 40,
            velocity: CGSize(width: 350, height: -1400), threshold: threshold,
        ) == nil)
    }

    @Test func `restore needs inward travel past the threshold`() {
        // Tucked trailing: inward is negative x.
        #expect(EditorPadTuckGeometry.restoresFromTuck(
            side: .trailing, projectedTranslationX: -threshold, threshold: threshold,
        ))
        #expect(!EditorPadTuckGeometry.restoresFromTuck(
            side: .trailing, projectedTranslationX: 1 - threshold, threshold: threshold,
        ))
        // Pushing further outward never restores.
        #expect(!EditorPadTuckGeometry.restoresFromTuck(
            side: .trailing, projectedTranslationX: threshold, threshold: threshold,
        ))
        // Tucked leading: inward is positive x.
        #expect(EditorPadTuckGeometry.restoresFromTuck(
            side: .leading, projectedTranslationX: threshold, threshold: threshold,
        ))
    }

    @Test func `restore preview aligns the card's inner edge with the handle's inner edge`() {
        let padWidth: CGFloat = 380
        let handleWidth: CGFloat = 36
        let margin: CGFloat = 12
        // Trailing tuck: for any shared translation t, the CARD's leading edge (frame leading (W - p) / 2 plus
        // margin plus base plus t) must equal the handle's leading edge (W - handleWidth plus t) — t cancels, so
        // verify the bases.
        let trailingBase = EditorPadTuckGeometry.restorePreviewRestOffsetX(
            side: .trailing, viewportWidth: 402, padWidth: padWidth, handleWidth: handleWidth, margin: margin,
        )
        #expect((402 - padWidth) / 2 + margin + trailingBase == 402 - handleWidth)
        // Leading tuck mirrors: the card's trailing edge lands on the handle's trailing edge (x = handleWidth).
        let leadingBase = EditorPadTuckGeometry.restorePreviewRestOffsetX(
            side: .leading, viewportWidth: 402, padWidth: padWidth, handleWidth: handleWidth, margin: margin,
        )
        #expect((402 + padWidth) / 2 - margin + leadingBase == handleWidth)
    }

    @Test func `handle hides once the drag commits to restoring`() {
        // At rest and on small pulls the handle stays up — releasing here snaps back to hidden.
        #expect(EditorPadTuckGeometry.handleVisible(side: .trailing, translationX: 0, threshold: threshold))
        #expect(EditorPadTuckGeometry.handleVisible(
            side: .trailing, translationX: -(threshold - 1), threshold: threshold,
        ))
        // Crossing the threshold inward is the moment it goes.
        #expect(!EditorPadTuckGeometry.handleVisible(side: .trailing, translationX: -threshold, threshold: threshold))
        // And an outward wobble keeps it visible.
        #expect(EditorPadTuckGeometry.handleVisible(side: .trailing, translationX: 30, threshold: threshold))
    }
}
