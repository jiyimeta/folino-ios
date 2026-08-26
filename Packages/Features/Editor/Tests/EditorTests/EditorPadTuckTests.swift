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

    @Test func `rest offset parks the pad just past the edge`() {
        let padWidth: CGFloat = 380
        let trailing = EditorPadTuckGeometry.restOffsetX(side: .trailing, viewportWidth: 402, padWidth: padWidth)
        // Centered rest puts the pad's leading edge at (W - p) / 2; the offset must carry it to exactly W.
        #expect((402 - padWidth) / 2 + trailing == 402)
        let leading = EditorPadTuckGeometry.restOffsetX(side: .leading, viewportWidth: 402, padWidth: padWidth)
        // Mirror image: the trailing edge lands at 0.
        #expect((402 + padWidth) / 2 + leading == 0)
    }

    @Test func `short drag repositions instead of tucking`() {
        #expect(
            EditorPadTuckGeometry.tuckDestination(projectedTranslationX: threshold - 1, threshold: threshold) == nil,
        )
        #expect(
            EditorPadTuckGeometry.tuckDestination(projectedTranslationX: 1 - threshold, threshold: threshold) == nil,
        )
    }

    @Test func `outward drag past threshold tucks toward the drag direction`() {
        #expect(
            EditorPadTuckGeometry.tuckDestination(projectedTranslationX: threshold, threshold: threshold) == .trailing,
        )
        #expect(
            EditorPadTuckGeometry.tuckDestination(projectedTranslationX: -threshold, threshold: threshold) == .leading,
        )
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
