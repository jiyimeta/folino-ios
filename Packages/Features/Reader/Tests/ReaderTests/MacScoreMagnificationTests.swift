import CoreGraphics
@testable import Reader
import Testing

/// The conversion that keeps a click on the Mac's magnifying score hosts landing on the measure the reader aimed at.
///
/// The numbers below are not invented: they are what a synthetic click aimed at content point (120, 200) was measured
/// to report through a `SpatialTapGesture` inside an `NSHostingView` under an `NSScrollView` at each magnification.
/// See `MacScoreMagnification.documentPoint(fromHosted:magnification:)`.
struct MacScoreMagnificationTests {
    private let documentPoint = CGPoint(x: 120, y: 200)

    @Test func `unit magnification leaves the point alone`() {
        let resolved = MacScoreMagnification.documentPoint(fromHosted: documentPoint, magnification: 1)
        #expect(resolved == documentPoint)
    }

    @Test func `a zoomed-in click is divided back into document space`() {
        let resolved = MacScoreMagnification.documentPoint(
            fromHosted: CGPoint(x: 240, y: 400), magnification: 2,
        )
        #expect(resolved == documentPoint)
    }

    @Test func `a zoomed-out click is divided back into document space`() {
        let resolved = MacScoreMagnification.documentPoint(
            fromHosted: CGPoint(x: 60, y: 100), magnification: 0.5,
        )
        #expect(resolved == documentPoint)
    }

    /// The regression this exists for: at any magnification other than 1, the SAME document point must come back, so
    /// two clicks on one notehead at two zoom levels resolve to one measure.
    @Test func `every magnification resolves the same visual point to the same document point`() {
        for magnification in [MacScoreMagnification.minimum, 0.5, 1, 1.75, 2, MacScoreMagnification.maximum] {
            let hosted = CGPoint(x: documentPoint.x * magnification, y: documentPoint.y * magnification)
            let resolved = MacScoreMagnification.documentPoint(fromHosted: hosted, magnification: magnification)
            #expect(abs(resolved.x - documentPoint.x) < 0.0001)
            #expect(abs(resolved.y - documentPoint.y) < 0.0001)
        }
    }

    @Test func `a magnification the scroll view cannot produce passes the point through`() {
        #expect(MacScoreMagnification.documentPoint(fromHosted: documentPoint, magnification: 0) == documentPoint)
        #expect(MacScoreMagnification.documentPoint(fromHosted: documentPoint, magnification: -2) == documentPoint)
        #expect(
            MacScoreMagnification.documentPoint(fromHosted: documentPoint, magnification: .nan) == documentPoint,
        )
    }

    @Test func `the fit seed is clamped to the range the scroll view enforces`() {
        #expect(MacScoreMagnification.clamped(0.01) == MacScoreMagnification.minimum)
        #expect(MacScoreMagnification.clamped(9) == MacScoreMagnification.maximum)
        #expect(MacScoreMagnification.clamped(0.8) == 0.8)
    }
}
