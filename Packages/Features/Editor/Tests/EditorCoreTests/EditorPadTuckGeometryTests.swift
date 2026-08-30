@testable import EditorCore
import Foundation
import Testing

@Suite("EditorPadTuckGeometry")
struct EditorPadTuckGeometryTests {
    /// iPhone 16 Pro portrait-ish viewport.
    private let viewportWidth: Double = 402
    private let viewportHeight: Double = 874
    private var threshold: Double {
        EditorPadTuckGeometry.threshold(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
    }

    @Test func `threshold is a fifth of the short side`() {
        #expect(threshold == 402 * 0.2)
        // Rotating the same screen must not change the felt distance.
        #expect(EditorPadTuckGeometry.threshold(viewportWidth: 874, viewportHeight: 402) == threshold)
    }

    @Test func `rest offset parks the pad's card just past the edge`() {
        let padWidth: Double = 380
        let margin: Double = 12
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

    /// The one thing the two platforms do differently: Android leaves a sliver of the card itself showing rather
    /// than parking it fully offscreen behind a tab.
    @Test func `peek leaves exactly that much of the card on screen`() {
        let padWidth: Double = 380
        let margin: Double = 8
        let peek: Double = 24
        let trailing = EditorPadTuckGeometry.restOffsetX(
            side: .trailing, viewportWidth: 402, padWidth: padWidth, margin: margin, peek: peek,
        )
        // The card's leading edge stops `peek` short of the screen's trailing edge.
        #expect((402 - padWidth) / 2 + margin + trailing == 402 - peek)
        let leading = EditorPadTuckGeometry.restOffsetX(
            side: .leading, viewportWidth: 402, padWidth: padWidth, margin: margin, peek: peek,
        )
        #expect((402 + padWidth) / 2 - margin + leading == peek)
        // A zero peek is the tab-and-nothing-else park, unchanged.
        #expect(EditorPadTuckGeometry.restOffsetX(
            side: .trailing, viewportWidth: 402, padWidth: padWidth, margin: margin, peek: 0,
        ) == EditorPadTuckGeometry.restOffsetX(
            side: .trailing, viewportWidth: 402, padWidth: padWidth, margin: margin,
        ))
    }

    @Test func `short drag repositions instead of tucking`() {
        // A release velocity pointing more sideways than vertically — the quick short hide-flick's shape.
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: threshold - 1, projectedTranslationX: threshold - 1,
            velocityX: 900, velocityY: 200, threshold: threshold,
        ) == nil)
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: 1 - threshold, projectedTranslationX: 1 - threshold,
            velocityX: 900, velocityY: 200, threshold: threshold,
        ) == nil)
    }

    @Test func `outward drag past threshold tucks toward the drag direction`() {
        // The finger actually covered the distance — velocity direction doesn't matter (the diagonal corner throw).
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: threshold, projectedTranslationX: threshold,
            velocityX: 300, velocityY: -1200, threshold: threshold,
        ) == .trailing)
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: -threshold, projectedTranslationX: -threshold,
            velocityX: -300, velocityY: -1200, threshold: threshold,
        ) == .leading)
    }

    @Test func `a quick sideways flick tucks on projection alone`() {
        // Short actual travel, but the release velocity points sideways: the deliberate hide-flick.
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: threshold / 3, projectedTranslationX: threshold + 50,
            velocityX: 900, velocityY: 200, threshold: threshold,
        ) == .trailing)
    }

    @Test func `a fast vertical dock flick with sideways drift does not tuck`() {
        // The projection clears the threshold only because the flick was fast; the finger barely moved sideways and
        // the velocity points up — this is a dock move, not a dismissal.
        #expect(EditorPadTuckGeometry.tuckDestination(
            translationX: 25, projectedTranslationX: threshold + 40,
            velocityX: 350, velocityY: -1400, threshold: threshold,
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
        let padWidth: Double = 380
        let handleWidth: Double = 36
        let margin: Double = 12
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

    /// The JNI boundary speaks integers; the round trip has to be exact or Kotlin's tuck side silently flips.
    @Test func `tuck side survives the JNI discriminator round trip`() {
        for side in EditorPadTuckSide.allCases {
            #expect(EditorPadTuckSide(rawIndex: side.rawIndex) == side)
        }
    }

    @Test func `placement survives the JNI discriminator round trip`() {
        for placement in EditorPadPlacement.allCases {
            #expect(EditorPadPlacement(rawIndex: placement.rawIndex) == placement)
        }
    }

    // MARK: - The vertical dock

    @Test func `the parked center sits half a pad in from the docked edge`() {
        let padHeight: Double = 120
        #expect(EditorPadTuckGeometry.parkedCenterY(
            placement: .bottom, viewportHeight: viewportHeight, padHeight: padHeight,
        ) == viewportHeight - padHeight / 2)
        #expect(EditorPadTuckGeometry.parkedCenterY(
            placement: .top, viewportHeight: viewportHeight, padHeight: padHeight,
        ) == padHeight / 2)
    }

    /// A short flick must not fly the pad across the screen: the decision is where the pad's own center LANDED,
    /// not how far the finger travelled.
    @Test func `a small nudge leaves the dock where it was`() {
        let padHeight: Double = 120
        let parked = EditorPadTuckGeometry.parkedCenterY(
            placement: .bottom, viewportHeight: viewportHeight, padHeight: padHeight,
        )
        #expect(EditorPadPlacement.nearest(toCenterY: parked - 40, in: viewportHeight) == .bottom)
        // Past the midpoint it re-docks, and the midpoint itself belongs to the bottom (`<` is strict).
        #expect(EditorPadPlacement.nearest(toCenterY: viewportHeight / 2, in: viewportHeight) == .bottom)
        #expect(EditorPadPlacement.nearest(toCenterY: viewportHeight / 2 - 1, in: viewportHeight) == .top)
    }

    @Test func `a throw from the bottom to the top re-docks`() {
        let padHeight: Double = 120
        let parked = EditorPadTuckGeometry.parkedCenterY(
            placement: .bottom, viewportHeight: viewportHeight, padHeight: padHeight,
        )
        // Projected travel far enough up to carry the pad's center into the upper half.
        let landed = parked - viewportHeight * 0.6
        #expect(EditorPadPlacement.nearest(toCenterY: landed, in: viewportHeight) == .top)
    }
}
