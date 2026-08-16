import Foundation

/// What a captured original's bytes actually are. Stored on `ScoreItem` so the confirmation dialog can be honest
/// about what reverting will produce without having to re-derive it from a row's history, which is not recorded.
///
/// The raw values are persisted in `score_items.original_provenance`; do not rename them.
public enum OriginalProvenance: String, Hashable, Sendable, Codable {
    /// The bytes folino imported, captured by this feature or recovered as an untouched source file.
    case importTime
    /// The score exactly as the PDF conversion wrote it. The PDF itself is a separate sidecar
    /// (`sourcePDFFileName`) and is not what this describes.
    case conversionOutput
    /// Captured from a row that predates this feature, where whether it had already been edited cannot be known.
    case legacyUnknown
}
