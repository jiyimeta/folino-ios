import CoreGraphics

/// Paper geometry for the Mac's page deck, and the mapping from a click on it back to a page and a document point.
///
/// **Deliberately outside `#if os(macOS)`.** None of this touches AppKit — it is `CGFloat`, `CGPoint` and `CGSize` —
/// and the package's tests run on an iOS Simulator destination, so macOS-gated geometry would compile only where no
/// test can reach it. The mapping below is the whole correctness of clicking on the Mac reader, so it is exactly the
/// part that has to be testable.
enum MacPageDeckMetrics {
    /// A4 in points (210 x 297 mm at 72 dpi).
    ///
    /// **The page is a fixed sheet, not the window.** iOS paginates to the viewport, because a phone or an iPad shows
    /// one page at a time and the page may as well be the screen. The Mac shows a deck of sheets that the user
    /// magnifies, so the sheet has to have a size of its own that does not move when the window is resized —
    /// otherwise every resize re-paginates the score and the page the reader was looking at is a different page
    /// afterwards. A4 is that size: the paper the engraving would be printed on.
    static let paperSize = CGSize(width: 595.28, height: 841.89)
    /// Half an inch of paper margin on every side, the printed-score convention.
    static let margin: CGFloat = 36
    /// Gap between two sheets in the deck.
    static let pageGap: CGFloat = 24
    /// Breathing room between the deck and the scroll view's edges.
    static let deckPadding: CGFloat = 24

    /// The printable area inside one sheet: what the score is engraved into and what pagination measures against.
    static var contentSize: CGSize {
        CGSize(width: paperSize.width - margin * 2, height: paperSize.height - margin * 2)
    }

    /// The drawn sheet size for a document of the given engraved width. Honoring the engraver's authored breaks can
    /// leave `doc.size.width` wider than the width it was engraved for; widening the sheet rather than clipping keeps
    /// every notehead on the paper.
    static func pageSize(forDocumentWidth width: CGFloat) -> CGSize {
        CGSize(width: max(paperSize.width, width + margin * 2), height: paperSize.height)
    }

    /// The printable area inside a sheet of `pageSize`.
    static func contentSize(forPageSize pageSize: CGSize) -> CGSize {
        CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
    }

    /// Origin of page `index` in the deck's own (unmagnified) coordinate space — the space a scroll-to-visible
    /// rectangle has to be expressed in, and the space a click arrives in.
    static func pageOrigin(index: Int, pageSize: CGSize) -> CGPoint {
        CGPoint(x: deckPadding + CGFloat(index) * (pageSize.width + pageGap), y: deckPadding)
    }

    /// Magnification that fits one whole sheet in the window, clamped to what the scroll view allows and never
    /// enlarging past 1.0 — a small score should open at actual size, not blown up to fill the window.
    static func fitMagnification(pageSize: CGSize, viewport: CGSize) -> CGFloat {
        let availableWidth = viewport.width - deckPadding * 2
        let availableHeight = viewport.height - deckPadding * 2
        guard pageSize.width > 0, pageSize.height > 0, availableWidth > 0, availableHeight > 0 else { return 1 }
        let fit = min(availableWidth / pageSize.width, availableHeight / pageSize.height, 1.0)
        return MacScoreMagnification.clamped(fit)
    }
}

/// Where a click on the page deck landed.
enum MacDeckClick: Equatable {
    /// Inside a sheet's printable area. `contentPoint` is relative to the top-left of that area, so adding the page's
    /// `pageStartY` gives the point in the document's own coordinates.
    case page(index: Int, contentPoint: CGPoint)
    /// The desk, the gap between two sheets, a sheet's paper margin, or the page-number row beneath a sheet. Not a
    /// seek and not a selection — while editing it is what clears the selection.
    case outside
}

/// The click mapping for both Mac score hosts.
///
/// **This exists because SwiftUI cannot be asked where a click landed inside a magnified `NSScrollView`.** Measured:
/// a click inside an `NSHostingView` whose enclosing clip view has scaled bounds is hit-tested at
/// `hostedPoint × magnification` against the hosted tree's UNSCALED layout frames. In the page deck every sheet's
/// layer is framed to the full document height and offset up by its own `pageStartY` (`.clipped()` clips drawing, not
/// hit testing), so those frames overlap vertically across the whole deck and the magnified point simply lands on a
/// different sheet's layer — at 1.7x, aiming at page 3 delivers the click to page 5, with the location reported
/// relative to page 5's coordinate space. No arithmetic on that location can recover the click, because the wrong
/// view received it.
///
/// So the click is taken on the AppKit side instead, where `NSView`'s own conversion through the clip view is correct
/// at every magnification, and mapped to a page here. `MacOriginalPDFView` already resolves its clicks the same way.
enum MacScoreClickMapping {
    /// Resolve a click on the page deck, given in the deck's own unmagnified coordinates (the hosting view's space).
    ///
    /// The deck is `deckPadding` around an `HStack` of `pageGap`-spaced sheets, each sheet a `pageSize` card whose
    /// printable area is inset by `margin`. Anything that is not inside a printable area — the desk, the gap, the
    /// paper margin, the page-number row below a card — is `.outside`.
    static func deckClick(hostedPoint: CGPoint, pageSize: CGSize, pageCount: Int) -> MacDeckClick {
        guard pageCount > 0, pageSize.width > 0, pageSize.height > 0 else { return .outside }
        let x = hostedPoint.x - MacPageDeckMetrics.deckPadding
        let y = hostedPoint.y - MacPageDeckMetrics.deckPadding
        let stride = pageSize.width + MacPageDeckMetrics.pageGap
        guard x >= 0, y >= 0, y <= pageSize.height else { return .outside }

        let index = Int((x / stride).rounded(.down))
        guard index >= 0, index < pageCount else { return .outside }
        // Past the card's trailing edge is the gap before the next sheet, not this sheet.
        let inCardX = x - CGFloat(index) * stride
        guard inCardX <= pageSize.width else { return .outside }

        let content = CGPoint(x: inCardX - MacPageDeckMetrics.margin, y: y - MacPageDeckMetrics.margin)
        let contentSize = MacPageDeckMetrics.contentSize(forPageSize: pageSize)
        guard content.x >= 0, content.y >= 0,
              content.x <= contentSize.width, content.y <= contentSize.height
        else { return .outside }
        return .page(index: index, contentPoint: content)
    }

    /// The document point for a click on the horizontal strip, given in the strip's own unmagnified coordinates.
    ///
    /// The strip is the engraving inset by `contentInset` on every side. `nil` for a click on that inset — the strip's
    /// equivalent of the deck's paper margin.
    static func stripDocumentPoint(
        hostedPoint: CGPoint, contentInset: CGFloat, documentSize: CGSize,
    ) -> CGPoint? {
        let point = CGPoint(x: hostedPoint.x - contentInset, y: hostedPoint.y - contentInset)
        guard point.x >= 0, point.y >= 0, point.x <= documentSize.width, point.y <= documentSize.height else {
            return nil
        }
        return point
    }
}
