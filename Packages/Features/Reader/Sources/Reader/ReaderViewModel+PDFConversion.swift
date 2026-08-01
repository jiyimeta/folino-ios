import Domain
import Foundation

// MARK: - Reading a PDF into notation

extension ReaderViewModel {
    /// Reads a PDF item into notation on the way to displaying it, so PDFs imported before folino learned to convert
    /// catch up the first time they're opened. Returns the score file's URL when the conversion produced one, `nil`
    /// when the item stays a PDF.
    ///
    /// A failure is sticky (`pdfConversionFailed`): OMR is expensive, and re-running it on every open of a PDF folino
    /// already knows it can't read would make those items feel broken. The re-read action is how the user retries.
    func convertPDFIfNeeded(url: URL) async -> URL? {
        guard scoreItem.pdfOriginState == .unconverted,
              !scoreItem.pdfConversionFailed,
              let pdfConversion
        else { return nil }

        isConvertingPDF = true
        defer { isConvertingPDF = false }

        // Back-fill the sidecar identity for rows that predate the PDF-origin columns: for a row that is still a PDF,
        // the sidecar IS the file it already points at.
        let sidecarName = scoreItem.sourcePDFFileName ?? scoreItem.localFileName
        let sidecarHash = scoreItem.sourcePDFContentHash ?? scoreItem.contentHash
        let destination = scoresDirectory.appending(
            path: "\(scoreItem.id.rawValue.uuidString).\(ScoreFormat.mscz.canonicalExtension)",
        )

        guard let facts = await pdfConversion(url, destination) else {
            await persist(scoreItem.markingPDFConversionFailed(
                sourcePDFFileName: sidecarName,
                sourcePDFContentHash: sidecarHash,
            ))
            return nil
        }
        await persist(scoreItem.adoptingPDFConversion(
            facts,
            sourcePDFFileName: sidecarName,
            sourcePDFContentHash: sidecarHash,
        ))
        return scoresDirectory.appending(path: facts.fileName)
    }

    private func persist(_ item: ScoreItem) async {
        scoreItem = item
        try? await repository.saveScoreItem(item)
    }
}
