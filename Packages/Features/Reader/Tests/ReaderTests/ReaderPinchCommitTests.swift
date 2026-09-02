import CoreGraphics
@testable import Reader
import Testing
import UIKit

struct ReaderPinchCommitTests {
    private func resolve(
        base: CGFloat,
        mag: CGFloat,
        start: CGPoint = .zero,
        offset: CGPoint = .zero,
        offX: CGFloat = 0,
        offY: CGFloat = 0,
    ) -> PinchCommitResult {
        ReaderPinchCommit.resolve(PinchCommitInput(
            baseZoom: base,
            magnification: mag,
            startLocation: start,
            currentOffset: offset,
            offsetX: offX,
            offsetY: offY,
        ))
    }

    @Test func `zoom in computes target and ratio`() {
        let r = resolve(base: 2, mag: 1.5)
        #expect(abs(r.targetZoom - 3) < 1e-9)
        #expect(abs(r.ratio - 1.5) < 1e-9)
        #expect(r.isBounceBack == false)
        #expect(r.snapToUnit == false)
    }

    @Test func `near unit snaps to one`() {
        let r = resolve(base: 1, mag: 1.02) // combined 1.02 < 1.05 → target 1
        #expect(abs(r.targetZoom - 1) < 1e-9)
        #expect(r.isBounceBack)
        #expect(r.snapToUnit)
    }

    @Test func `zoom out to unit is snap not bounce`() {
        let r = resolve(base: 3, mag: 0.2) // combined 0.6 → target 1, base 3 > 1 → not bounce
        #expect(abs(r.targetZoom - 1) < 1e-9)
        #expect(r.isBounceBack == false)
        #expect(r.snapToUnit)
        #expect(abs(r.compensatedMag - 0.6) < 1e-9)
    }

    @Test func `scroll target keeps point and subtracts offsets`() {
        // ratio 2 around start (100,200) from offset (10,20), live offsets (5,7):
        // x = 10 + 100·1 − 5 = 105 ; y = 20 + 200·1 − 7 = 213.
        let r = resolve(
            base: 1,
            mag: 2,
            start: CGPoint(x: 100, y: 200),
            offset: CGPoint(x: 10, y: 20),
            offX: 5,
            offY: 7,
        )
        #expect(abs(r.rawScrollTarget.x - 105) < 1e-9)
        #expect(abs(r.rawScrollTarget.y - 213) < 1e-9)
    }

    // MARK: clampScrollTarget — the range clamp shared by the host and the pinch-commit residual seed.

    private func clamp(
        _ raw: CGPoint,
        content: CGSize,
        bounds: CGSize,
        inset: UIEdgeInsets = .zero,
    ) -> (clamped: CGPoint, residual: CGPoint) {
        ReaderPinchCommit.clampScrollTarget(
            raw, contentSize: content, bounds: bounds,
            insetLeft: inset.left, insetRight: inset.right, insetTop: inset.top, insetBottom: inset.bottom,
        )
    }

    @Test func `in-range target is unchanged with zero residual`() {
        // content 200×200, bounds 100×100, inset 0 → valid range [0,100]×[0,100]. This is the seamless-commit path:
        // the anchor-preserving target already sits in range, so residual must be zero (no ease introduced).
        let (clamped, residual) = clamp(
            CGPoint(x: 40, y: 60), content: CGSize(width: 200, height: 200), bounds: CGSize(width: 100, height: 100),
        )
        #expect(clamped == CGPoint(x: 40, y: 60))
        #expect(residual == .zero)
    }

    @Test func `below-range clamps up, positive residual, other axis untouched`() {
        // raw.x −30 (below minX 0) → clamped.x 0, residual.x +30; raw.y 60 in range → residual.y 0 (axis independence).
        let (clamped, residual) = clamp(
            CGPoint(x: -30, y: 60), content: CGSize(width: 200, height: 200), bounds: CGSize(width: 100, height: 100),
        )
        #expect(clamped.x == 0)
        #expect(residual.x == 30)
        #expect(clamped.y == 60)
        #expect(residual.y == 0)
    }

    @Test func `above-range clamps down with negative residual`() {
        // maxX = content 200 − bounds 100 = 100 ; raw.x 150 → clamped 100, residual −50.
        let (clamped, residual) = clamp(
            CGPoint(x: 150, y: 60), content: CGSize(width: 200, height: 200), bounds: CGSize(width: 100, height: 100),
        )
        #expect(clamped.x == 100)
        #expect(residual.x == -50)
    }

    @Test func `collapsed range clamps to the single valid point`() {
        // Content fits bounds (80 < 100) → maxX = max(0, 80 − 100) = 0 → range collapses to {0} (paged snap-to-unit).
        let (clamped, residual) = clamp(
            CGPoint(x: 25, y: -10), content: CGSize(width: 80, height: 80), bounds: CGSize(width: 100, height: 100),
        )
        #expect(clamped == .zero)
        #expect(residual == CGPoint(x: -25, y: 10))
    }

    @Test func `centering inset shifts the valid range`() {
        // Horizontal-mode vertical centering: inset.top = inset.bottom = 20, short content (60 < bounds 100) →
        // minY = −20 ; maxY = max(−20, 60 + 20 − 100) = −20 → Y range {−20}. Mirrors HorizontalScoreContainer's
        // `max(-postInsetTop, ·)` pre-clamp.
        let inset = UIEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
        let (clamped, residual) = clamp(
            CGPoint(x: 0, y: 5), content: CGSize(width: 300, height: 60), bounds: CGSize(width: 100, height: 100),
            inset: inset,
        )
        #expect(clamped.y == -20)
        #expect(residual.y == -25)
    }

    @Test func `clamped equals raw plus residual`() {
        let raw = CGPoint(x: 130, y: -40)
        let (clamped, residual) = clamp(
            raw, content: CGSize(width: 200, height: 150), bounds: CGSize(width: 100, height: 100),
        )
        #expect(clamped.x == raw.x + residual.x)
        #expect(clamped.y == raw.y + residual.y)
    }

    @Test func `overscroll past leading edge yields a right-holding seed sign`() {
        // Case-1 regression guard: panning past the leading edge makes the anchor-preserving target negative, so the
        // residual (= seed offset) is positive → content is held to the right at release and eases left to flush.
        let (_, residual) = clamp(
            CGPoint(x: -80, y: 0), content: CGSize(width: 500, height: 500), bounds: CGSize(width: 100, height: 100),
        )
        #expect(residual.x > 0)
    }
}
