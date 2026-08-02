import Domain
import Foundation
import PDFKit

// MARK: - Score vs. original PDF

extension ReaderViewModel {
    /// Whether the reader should offer the score / original-PDF switch. Only an item whose PDF folino actually read
    /// has two things to switch between: one it couldn't read shows the original with no switch, and an item that
    /// never came from a PDF has no original at all.
    var canShowOriginalPDF: Bool {
        scoreItem.pdfOriginState == .converted
    }

    /// Switch what the reader is showing. Opening the original document is deferred to the first switch, so a session
    /// that never leaves the notation never pays for it.
    ///
    /// Capabilities follow the source, which is what makes every inspector row and toolbar button do the right thing
    /// without a single call site knowing about PDFs: a fixed-layout page can't be re-engraved, so staff size, breaks,
    /// part visibility, clef overrides, transpose, and horizontal mode all disappear while the original is up, and
    /// come back on the way out. Tempo, A4, mixer, master volume, transport, and annotation are untouched — they don't
    /// depend on engraving.
    func setDisplaySource(_ source: ReaderDisplaySource) {
        guard source != displaySource else { return }
        if source == .originalPDF, originalPDFDocument == nil {
            guard let name = scoreItem.originalPDFFileName,
                  let doc = PDFDocument(url: scoresDirectory.appending(path: name)),
                  doc.pageCount > 0
            else { return }
            originalPDFDocument = doc
        }
        displaySource = source
        capabilities = ReaderCapabilities.resolve(
            format: ScoreFormat.detect(filename: scoreItem.localFileName),
            displaySource: source,
        )
        analytics.log(.displaySourceChanged(source))
        if source == .originalPDF {
            // The on-PDF cursor needs the OMR geometry, which a converted item no longer parses at open time. Off the
            // switch itself so the pages appear immediately.
            Task { [weak self] in await self?.prepareOriginalPDFCursorIfNeeded() }
        }
    }

    /// Flip to whichever source isn't showing. What the toolbar button does.
    func toggleDisplaySource() {
        setDisplaySource(displaySource == .score ? .originalPDF : .score)
    }
}
