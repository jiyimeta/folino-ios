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
        guard sourcePDFFileName != nil else { return .notPDF }
        let isStillPDF = ScoreFormat.detect(filename: localFileName) == .pdf
        return (!isStillPDF && pdfDerivedContentHash != nil) ? .converted : .unconverted
    }

    /// Whether the user has edited the notation since the conversion wrote it. False for anything that didn't come
    /// from a PDF — there is no conversion output to compare against.
    public var isPDFDerivedScoreEdited: Bool {
        guard let derived = pdfDerivedContentHash else { return false }
        return derived != contentHash
    }
}
