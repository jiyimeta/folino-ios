import Foundation

/// Where an item's notation came from, and how far the PDF → score conversion got. Derived, never stored — the fields
/// on `ScoreItem` are the state; this is the one place that reads them, so iOS and Android cannot disagree about what
/// a PDF-origin item is.
public enum PDFOriginState: Hashable, Sendable {
    /// Never came from a PDF.
    case notPDF
    /// Came from a PDF and is still displayed as one: the conversion hasn't run yet, or it failed.
    case unconverted
    /// Came from a PDF and is now a real score. The original stays on disk as a sidecar.
    case converted
}

extension ScoreItem {
    public var pdfOriginState: PDFOriginState {
        // An item whose bytes are a PDF is unconverted, full stop — `sourcePDFFileName` is deliberately NOT consulted
        // here. Rows imported before that column existed carry `nil`, and keying off it would classify every PDF
        // already in someone's library as "never came from a PDF": no conversion on open, no badge, no re-read, no
        // notice. The sidecar name only distinguishes converted from not, and the conversion back-fills it.
        if ScoreFormat.detect(filename: localFileName) == .pdf { return .unconverted }
        guard sourcePDFFileName != nil, pdfDerivedContentHash != nil else { return .notPDF }
        return .converted
    }

    /// The original PDF backing this item, or `nil` when there isn't one. Falls back to `localFileName` for a row that
    /// still *is* a PDF, which is how items imported before the origin columns existed keep working: the conversion
    /// back-fills `sourcePDFFileName` the first time it runs.
    public var originalPDFFileName: String? {
        if let sourcePDFFileName { return sourcePDFFileName }
        return ScoreFormat.detect(filename: localFileName) == .pdf ? localFileName : nil
    }

    /// Hash of the original PDF's bytes, with the same back-fill as `originalPDFFileName`.
    public var originalPDFContentHash: String? {
        if let sourcePDFContentHash { return sourcePDFContentHash }
        return ScoreFormat.detect(filename: localFileName) == .pdf ? contentHash : nil
    }

    /// Whether the user has edited the notation since the conversion wrote it. False for anything that didn't come
    /// from a PDF — there is no conversion output to compare against.
    public var isPDFDerivedScoreEdited: Bool {
        guard let derived = pdfDerivedContentHash else { return false }
        return derived != contentHash
    }
}
