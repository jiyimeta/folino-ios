import Foundation

/// Selectable share format on a library row.
///
/// MuseScore-version variants emit `.mscz` (re-encoded through the
/// `swift-sheet-music` MSCX encoder) for items whose source differs
/// from the chosen wire version. When the chosen format matches the
/// source verbatim, callers return the original bytes.
public enum ScoreShareFormat: Hashable, Sendable {
    case museScoreV4
    case museScoreV3
    case pdf
    case midi
}

/// One row in the share menu — a `format` plus whether it matches the
/// item's source representation. `isOriginal == true` means picking
/// this format yields the original file bytes; the UI annotates the
/// row accordingly.
public struct ScoreShareFormatOption: Hashable, Sendable {
    public let format: ScoreShareFormat
    public let isOriginal: Bool

    public init(format: ScoreShareFormat, isOriginal: Bool = false) {
        self.format = format
        self.isOriginal = isOriginal
    }
}

/// Materializes a `ScoreItem` in a requested share format as a temporary
/// file and returns its URL. Domain-pure: no UI, no UTType, no locale.
///
/// `availableFormats(for:)` is `async` because the implementation
/// inspects the item's parsed `Score.source` (loaded via the score
/// gateway) to decide which option to flag as "original" — that load
/// happens on demand when the menu opens, not eagerly per row.
public protocol ScoreShareService: Sendable {
    /// Selectable formats for this item, in display order. Every item
    /// reports the same four formats; the option flagged `isOriginal`
    /// is the one that re-emits the file as-is for that source. The
    /// implementation derives the flag from the parsed `Score.source`,
    /// so MIDI / MuseScore (v3 or v4) sources all light up the
    /// matching menu entry. MusicXML / PDF / unknown sources have no
    /// matching share format, so no row is flagged.
    func availableFormats(for item: ScoreItem) async -> [ScoreShareFormatOption]

    /// Materialize the chosen format as a temporary file and return its
    /// URL. The implementation manages the temp directory; callers must
    /// not delete the returned file. When `format` matches the item's
    /// source, the implementation returns the original bytes verbatim
    /// (preserving the source's container extension).
    func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat
    ) async throws -> URL
}
