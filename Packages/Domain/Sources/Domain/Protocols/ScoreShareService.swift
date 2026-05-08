import Foundation

/// Selectable share format on a library row.
///
/// `.msczOriginal` shares the imported file as-is — for `.mscz` items
/// it's a byte copy; for `.mscx` items it's a thin MSCZ wrapper around
/// the original XML. The MuseScore-version variants re-encode through
/// `swift-sheet-music`'s MSCX encoder and only apply to items whose
/// source format is not already `.mscx`/`.mscz`.
public enum ScoreShareFormat: Hashable, Sendable {
    case msczOriginal
    case msczMuseScore4
    case msczMuseScore3
    case pdf
    case midi
}

/// Materializes a `ScoreItem` in a requested share format as a temporary
/// file and returns its URL. Domain-pure: no UI, no UTType, no locale.
public protocol ScoreShareService: Sendable {
    /// Selectable formats for this item, in display order.
    ///
    /// Items with an `.mscx` or `.mscz` on-disk format report
    /// `[.msczOriginal, .pdf, .midi]`. All other items (MusicXML/MXL/
    /// MIDI) report `[.msczMuseScore4, .msczMuseScore3, .pdf, .midi]`
    /// — the originals can't be shared as MSCZ without re-encoding,
    /// so the menu exposes the version choice instead.
    func availableFormats(for item: ScoreItem) -> [ScoreShareFormat]

    /// Materialize the chosen format as a temporary file and return its
    /// URL. The implementation manages the temp directory; callers must
    /// not delete the returned file.
    func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat
    ) async throws -> URL
}
