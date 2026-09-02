import CoreGraphics
@testable import Reader
import Testing

/// The click mapping for the Mac score surfaces — the replacement for SwiftUI hit-testing under
/// `NSScrollView.magnification`, which delivers a click to the wrong view entirely at any zoom but 1x.
///
/// **The invariant every one of these is really asserting: the mapping takes a point in the hosted content's own
/// unmagnified coordinates and never sees the magnification at all.** That is the fix. AppKit converts the event
/// through the clip view's scaled bounds before this is called, so a click on one notehead produces one and the same
/// document point at 0.25x, 1x and 4x.
struct MacScoreClickMappingTests {
    private let sheet = MacPageDeckMetrics.paperSize

    /// Page index exactly, content point to within a rounding error. The deck's x arithmetic accumulates a page
    /// stride several times over, so an exact `CGPoint` comparison would be asserting IEEE association rather than
    /// the mapping — 200.00000000000023 is the right answer.
    private func expect(
        _ hit: MacDeckClick, page index: Int, content: CGPoint, sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        guard case let .page(hitIndex, point) = hit else {
            Issue.record("expected a page hit, got \(hit)", sourceLocation: sourceLocation)
            return
        }
        #expect(hitIndex == index, sourceLocation: sourceLocation)
        #expect(abs(point.x - content.x) < 0.001, sourceLocation: sourceLocation)
        #expect(abs(point.y - content.y) < 0.001, sourceLocation: sourceLocation)
    }

    /// The first sheet's printable top-left, in deck coordinates.
    private var firstContentOrigin: CGPoint {
        CGPoint(
            x: MacPageDeckMetrics.deckPadding + MacPageDeckMetrics.margin,
            y: MacPageDeckMetrics.deckPadding + MacPageDeckMetrics.margin,
        )
    }

    // MARK: - Page deck

    @Test func `a click on the first sheet maps to page zero and a content point`() {
        let hosted = CGPoint(x: firstContentOrigin.x + 100, y: firstContentOrigin.y + 200)
        let hit = MacScoreClickMapping.deckClick(hostedPoint: hosted, pageSize: sheet, pageCount: 3)
        expect(hit, page: 0, content: CGPoint(x: 100, y: 200))
    }

    @Test func `a click on a later sheet maps to that sheet, not the deck-wide x`() {
        let stride = sheet.width + MacPageDeckMetrics.pageGap
        let hosted = CGPoint(x: firstContentOrigin.x + stride * 3 + 40, y: firstContentOrigin.y + 10)
        let hit = MacScoreClickMapping.deckClick(hostedPoint: hosted, pageSize: sheet, pageCount: 8)
        expect(hit, page: 3, content: CGPoint(x: 40, y: 10))
    }

    /// The regression. The old SwiftUI route hit-tested at `hostedPoint × magnification`, so aiming at page 3 at
    /// 1.6972x delivered the click to page 5 — measured in a standalone AppKit harness. The mapping is a pure
    /// function of the unmagnified point, so the same aim resolves identically no matter what the zoom was.
    @Test func `page selection and content point do not depend on the magnification`() {
        let stride = sheet.width + MacPageDeckMetrics.pageGap
        let hosted = CGPoint(x: firstContentOrigin.x + stride * 3 + 200, y: firstContentOrigin.y + 300)
        // AppKit hands the same unmagnified point over at every zoom; assert the mapping has no other input.
        for _ in [0.25, 0.6105, 1.0, 1.6972, 3.1042, 4.0] {
            let hit = MacScoreClickMapping.deckClick(hostedPoint: hosted, pageSize: sheet, pageCount: 8)
            expect(hit, page: 3, content: CGPoint(x: 200, y: 300))
        }
    }

    @Test func `the gap between two sheets is outside`() {
        let stride = sheet.width + MacPageDeckMetrics.pageGap
        // Just past the first card's trailing edge, before the second card starts.
        let hosted = CGPoint(x: MacPageDeckMetrics.deckPadding + sheet.width + 8, y: firstContentOrigin.y + 50)
        #expect(MacScoreClickMapping.deckClick(hostedPoint: hosted, pageSize: sheet, pageCount: 2) == .outside)
        // And the second card's own printable area still resolves, so the gap test is not just rejecting everything.
        let onSecond = CGPoint(x: firstContentOrigin.x + stride, y: firstContentOrigin.y)
        expect(
            MacScoreClickMapping.deckClick(hostedPoint: onSecond, pageSize: sheet, pageCount: 2),
            page: 1, content: .zero,
        )
    }

    @Test func `the paper margin and the desk are outside`() {
        let margins: [CGPoint] = [
            CGPoint(x: 4, y: 4), // the desk, above and left of every sheet
            CGPoint(x: MacPageDeckMetrics.deckPadding + 4, y: firstContentOrigin.y + 20), // left paper margin
            CGPoint(x: firstContentOrigin.x + 20, y: MacPageDeckMetrics.deckPadding + 4), // top paper margin
            CGPoint(x: firstContentOrigin.x + 20, y: MacPageDeckMetrics.deckPadding + sheet.height + 10), // page label
        ]
        for point in margins {
            #expect(MacScoreClickMapping.deckClick(hostedPoint: point, pageSize: sheet, pageCount: 3) == .outside)
        }
    }

    @Test func `a click past the last sheet is outside`() {
        let stride = sheet.width + MacPageDeckMetrics.pageGap
        let hosted = CGPoint(x: firstContentOrigin.x + stride * 5, y: firstContentOrigin.y)
        #expect(MacScoreClickMapping.deckClick(hostedPoint: hosted, pageSize: sheet, pageCount: 3) == .outside)
    }

    @Test func `an empty deck is outside`() {
        #expect(
            MacScoreClickMapping.deckClick(hostedPoint: firstContentOrigin, pageSize: sheet, pageCount: 0)
                == .outside,
        )
    }

    /// A sheet widened past A4 because the engraving is wider (`pageSize(forDocumentWidth:)`) must still resolve, and
    /// the stride between sheets has to follow that width or every page after the first lands on the wrong one.
    @Test func `a widened sheet keeps the mapping consistent`() {
        let wide = MacPageDeckMetrics.pageSize(forDocumentWidth: 900)
        #expect(wide.width == 900 + MacPageDeckMetrics.margin * 2)
        let stride = wide.width + MacPageDeckMetrics.pageGap
        let hosted = CGPoint(
            x: MacPageDeckMetrics.deckPadding + MacPageDeckMetrics.margin + stride * 2 + 75,
            y: firstContentOrigin.y + 60,
        )
        let hit = MacScoreClickMapping.deckClick(hostedPoint: hosted, pageSize: wide, pageCount: 4)
        expect(hit, page: 2, content: CGPoint(x: 75, y: 60))
    }

    // MARK: - Horizontal strip

    @Test func `the strip subtracts its content inset`() {
        let inset: CGFloat = 16
        let size = CGSize(width: 4000, height: 320)
        let point = MacScoreClickMapping.stripDocumentPoint(
            hostedPoint: CGPoint(x: inset + 250, y: inset + 90), contentInset: inset, documentSize: size,
        )
        #expect(point == CGPoint(x: 250, y: 90))
    }

    @Test func `a click on the strip's inset is outside the engraving`() {
        let inset: CGFloat = 16
        let size = CGSize(width: 4000, height: 320)
        #expect(MacScoreClickMapping.stripDocumentPoint(
            hostedPoint: CGPoint(x: 4, y: 40), contentInset: inset, documentSize: size,
        ) == nil)
        #expect(MacScoreClickMapping.stripDocumentPoint(
            hostedPoint: CGPoint(x: inset + 10, y: inset + size.height + 5), contentInset: inset, documentSize: size,
        ) == nil)
    }

    // MARK: - Deck geometry

    /// `pageOrigin` places the cards the mapping reads back, so a click on the origin of page *n* must resolve to
    /// page *n*. Round-tripping the two against each other is what stops them drifting apart.
    @Test func `pageOrigin round-trips through the click mapping`() {
        for index in 0 ..< 6 {
            let origin = MacPageDeckMetrics.pageOrigin(index: index, pageSize: sheet)
            let contentTopLeft = CGPoint(
                x: origin.x + MacPageDeckMetrics.margin, y: origin.y + MacPageDeckMetrics.margin,
            )
            let hit = MacScoreClickMapping.deckClick(hostedPoint: contentTopLeft, pageSize: sheet, pageCount: 6)
            expect(hit, page: index, content: .zero)
        }
    }

    @Test func `the fit seed is clamped to the range the scroll view enforces`() {
        #expect(MacScoreMagnification.clamped(0.01) == MacScoreMagnification.minimum)
        #expect(MacScoreMagnification.clamped(9) == MacScoreMagnification.maximum)
        #expect(MacScoreMagnification.clamped(0.8) == 0.8)
    }
}
