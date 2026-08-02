import Foundation

/// Which rendition of an item a stroke was drawn on. An item read out of a PDF has two — the engraved notation and the
/// original pages — and a stroke belongs to exactly one of them: the anchor kind says which.
public enum AnnotationRendition: Hashable, Sendable {
    /// The engraved notation. Anchored musically, so it survives reflow and staff-size changes.
    case score
    /// The original PDF's fixed-layout pages.
    case originalPDF
}

extension DrawingAnchorKind {
    public var rendition: AnnotationRendition {
        switch self {
        case .musical: .score
        case .page: .originalPDF
        }
    }
}

/// Keeping the two ink layers of one item apart.
///
/// Both renditions store their strokes in the same per-item array, told apart by anchor kind. A surface can only
/// capture the kind it draws, so committing a capture verbatim would delete the other rendition's ink — and the save
/// coordinator would persist that deletion, making it look as though switching views threw the drawings away. Every
/// capture goes through here instead.
public enum AnnotationLayers {
    /// The array with `rendition`'s strokes replaced by `captured`, and the other rendition's left exactly as they
    /// were. Order puts the untouched layer first so a repeated capture converges instead of shuffling.
    public static func replacing(
        _ rendition: AnnotationRendition,
        in existing: [DrawingAnchor],
        with captured: [DrawingAnchor],
    ) -> [DrawingAnchor] {
        existing.filter { $0.kind.rendition != rendition } + captured
    }

    /// The strokes belonging to one rendition. What a surface should be asked to display.
    public static func strokes(
        of rendition: AnnotationRendition,
        in drawings: [DrawingAnchor],
    ) -> [DrawingAnchor] {
        drawings.filter { $0.kind.rendition == rendition }
    }
}
