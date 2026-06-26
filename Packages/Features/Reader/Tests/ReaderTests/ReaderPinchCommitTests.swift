import CoreGraphics
@testable import Reader
import Testing

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
}
