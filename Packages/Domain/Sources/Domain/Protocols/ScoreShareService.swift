import Foundation

/// Selectable share format on a library row. `.sourceFormat` is the
/// "share what came in" entry; the concrete on-disk format it resolves
/// to depends on the item — see `ScoreShareService.resolvedSourceFormat(for:)`.
public enum ScoreShareFormat: Hashable, Sendable {
    case sourceFormat
    case pdf
    case midi
}

/// Materializes a `ScoreItem` in a requested share format as a temporary
/// file and returns its URL. Domain-pure: no UI, no UTType, no locale.
public protocol ScoreShareService: Sendable {
    /// Selectable formats for this item, in display order. All v1 items
    /// return `[.sourceFormat, .pdf, .midi]`.
    func availableFormats(for item: ScoreItem) -> [ScoreShareFormat]

    /// What the source-format entry resolves to for this item. Library
    /// uses this to build the menu label. `.mscx` resolves to `.mscz`
    /// (wrapped via MSCZWriter); other formats resolve to themselves.
    func resolvedSourceFormat(for item: ScoreItem) -> ScoreFormat

    /// Materialize the chosen format as a temporary file and return its
    /// URL. The implementation manages the temp directory; callers must
    /// not delete the returned file.
    func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat
    ) async throws -> URL
}
