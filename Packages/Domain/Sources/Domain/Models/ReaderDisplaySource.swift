import Foundation

/// Which rendition of a PDF-derived item the Reader is showing. Orthogonal to `ReaderLayoutMode`: each source carries
/// its own set of allowed layout modes, which is why this is a separate axis and not a fourth layout mode — folding
/// the original into the mode picker would cost the user the page/vertical choice on the original's side.
public enum ReaderDisplaySource: String, Hashable, Sendable, Codable {
    /// The engraved notation — the default, and the only option for an item that never came from a PDF.
    case score
    /// The original PDF's pages, fixed-layout, exactly as the file was imported.
    case originalPDF
}
