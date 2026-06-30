import Foundation

/// Where a freehand drawing is pinned. Scores anchor to a musical position (survives reflow / staff-size changes);
/// PDFs anchor to a fixed page. One `DrawingAnchor` carries exactly one kind. The Reader projects each kind to screen
/// coordinates with its own anchoring (`AnnotationAnchoring` for `.musical`, `PDFAnnotationAnchoring` for `.page`).
public enum DrawingAnchorKind: Hashable, Sendable, Codable {
    case musical(MusicalAnchor)
    case page(PageAnchor)
}

/// A fixed-layout page position. PDFs never reflow, so the page index plus the stroke geometry (stored normalized to
/// the page's own coordinate frame, 0…1 of the page width) fully locate a stroke. No fractional centroid is stored —
/// the normalized stroke bytes carry the within-page position, mirroring how `MusicalAnchor` + normalized bytes work
/// for scores.
public struct PageAnchor: Hashable, Sendable, Codable {
    public let pageIndex: Int

    public init(pageIndex: Int) {
        self.pageIndex = max(0, pageIndex)
    }
}
