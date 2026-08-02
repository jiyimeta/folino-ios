import Foundation

extension ScoreItem {
    /// The row as it looks once the original PDF has been read into notation and the score written to disk.
    ///
    /// The user's own labels survive: `title` (they may have renamed it), tags, favorite, and the trash stamp are all
    /// carried over. Everything derived from the file's contents comes from the conversion. Used by the Reader for
    /// both the one-time conversion of a PDF imported before folino could read one and the explicit re-read, so the
    /// two can't disagree about which fields a conversion owns.
    ///
    /// - Parameter sourcePDFFileName: the sidecar to record. Pass the item's current `localFileName` when converting
    ///   a row that is still a PDF; pass the existing `sourcePDFFileName` when re-reading one that isn't.
    public func adoptingPDFConversion(
        _ facts: PDFConversionFacts,
        sourcePDFFileName: String,
        sourcePDFContentHash: String?,
    ) -> ScoreItem {
        rebuilt(
            localFileName: facts.fileName,
            contentHash: facts.contentHash,
            sizeBytes: facts.sizeBytes,
            summary: facts.summary,
            sourcePDFFileName: sourcePDFFileName,
            sourcePDFContentHash: sourcePDFContentHash,
            pdfDerivedContentHash: facts.contentHash,
            pdfConversionFailed: false,
        )
    }

    /// The row as it looks after a conversion attempt that couldn't read music out of the PDF. The item keeps being a
    /// PDF; the flag stops the next open from paying for the same failed OMR pass.
    public func markingPDFConversionFailed(
        sourcePDFFileName: String,
        sourcePDFContentHash: String?,
    ) -> ScoreItem {
        rebuilt(
            localFileName: localFileName,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            summary: nil,
            sourcePDFFileName: sourcePDFFileName,
            sourcePDFContentHash: sourcePDFContentHash,
            pdfDerivedContentHash: pdfDerivedContentHash,
            pdfConversionFailed: true,
        )
    }

    /// `contentHash` is immutable per instance, so any change to it goes through the memberwise initializer. A `nil`
    /// `summary` leaves every content-derived field as it was.
    private func rebuilt(
        localFileName: String,
        contentHash: String,
        sizeBytes: Int64,
        summary: ScoreFileSummary?,
        sourcePDFFileName: String?,
        sourcePDFContentHash: String?,
        pdfDerivedContentHash: String?,
        pdfConversionFailed: Bool,
    ) -> ScoreItem {
        ScoreItem(
            id: id,
            title: title,
            subtitle: summary?.subtitle ?? subtitle,
            composer: summary?.composer ?? composer,
            arranger: summary?.arranger ?? arranger,
            lyricist: summary?.lyricist ?? lyricist,
            copyright: summary?.copyright ?? copyright,
            instrumentationSummary: summary?.instrumentationSummary ?? instrumentationSummary,
            localFileName: localFileName,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            lengthBeats: summary?.lengthBeats ?? lengthBeats,
            defaultTempoBpm: summary?.defaultTempoBpm ?? defaultTempoBpm,
            primaryKey: summary?.primaryKey ?? primaryKey,
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt,
            tagIDs: tagIDs,
            isFavorite: isFavorite,
            deletedAt: deletedAt,
            museScoreMajorVersion: summary?.museScoreMajorVersion ?? museScoreMajorVersion,
            sourcePDFFileName: sourcePDFFileName,
            sourcePDFContentHash: sourcePDFContentHash,
            pdfDerivedContentHash: pdfDerivedContentHash,
            pdfConversionFailed: pdfConversionFailed,
        )
    }
}
