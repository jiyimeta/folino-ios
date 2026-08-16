import Foundation

extension ScoreItem {
    /// Where a copied original goes: the item's own stem, marked, keeping the current file's extension so
    /// `ScoreFormat.detect` — which reads only the last extension — still identifies it.
    public var originalSidecarFileName: String {
        let stem = URL(fileURLWithPath: localFileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: localFileName).pathExtension
        return "\(stem).original.\(ext)"
    }

    /// Files that, if one of them is on disk beside the score, IS this item's untouched import. Only reachable for a
    /// MusicXML / MXL / MIDI import whose first edit wrote a sibling `.mscz` and left the source behind — before this
    /// feature that orphan was a leak; here it is the original. PDF is excluded: `sourcePDFFileName` owns that file.
    ///
    /// Canonical extensions only, because `localFileName == "<id>.<canonical-extension>"` is enforced at import.
    public var adoptableSourceFileNames: [String] {
        let stem = URL(fileURLWithPath: localFileName).deletingPathExtension().lastPathComponent
        return [ScoreFormat.musicXML, .mxl, .midi].map { "\(stem).\($0.canonicalExtension)" }
    }

    public var canRevertToOriginal: Bool {
        originalFileName != nil
    }

    /// The row once an original has been captured. Nothing else about the item changes — capture happens *before* the
    /// write that would make it necessary, so no content-derived field has moved yet.
    public func capturingOriginal(
        fileName: String,
        contentHash: String,
        provenance: OriginalProvenance,
    ) -> ScoreItem {
        var copy = self
        copy.originalFileName = fileName
        copy.originalContentHash = contentHash
        copy.originalProvenance = provenance
        return copy
    }
}

/// What a restored original turned out to be on disk, plus a fresh parse of it.
public struct RevertedOriginalFacts: Hashable, Sendable {
    public let localFileName: String
    public let contentHash: String
    public let sizeBytes: Int64
    public let summary: ScoreFileSummary

    public init(localFileName: String, contentHash: String, sizeBytes: Int64, summary: ScoreFileSummary) {
        self.localFileName = localFileName
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.summary = summary
    }
}

extension ScoreItem {
    /// The row once the original's bytes are back.
    ///
    /// Content-derived fields are *replaced*, not merged — unlike `adoptingPDFConversion`, which keeps a field the
    /// conversion couldn't supply. Here the file is authoritative by definition: leaving `lengthBeats` describing the
    /// edited version would simply be wrong. Credits are the user's, so they move only when asked, and even then a
    /// file with no title cannot blank a title the item is required to have. Tags, favourite, the trash stamp, the
    /// date added and every PDF-origin field are untouched; reverting to a conversion's output restores
    /// `contentHash == pdfDerivedContentHash` on its own.
    public func adoptingRevertedOriginal(
        _ facts: RevertedOriginalFacts,
        restoringScoreInfo: Bool,
    ) -> ScoreItem {
        let credits = restoringScoreInfo ? facts.summary : nil
        return ScoreItem(
            id: id,
            title: credits?.title ?? title,
            subtitle: restoringScoreInfo ? credits?.subtitle : subtitle,
            composer: restoringScoreInfo ? credits?.composer : composer,
            arranger: restoringScoreInfo ? credits?.arranger : arranger,
            lyricist: restoringScoreInfo ? credits?.lyricist : lyricist,
            copyright: restoringScoreInfo ? credits?.copyright : copyright,
            instrumentationSummary: facts.summary.instrumentationSummary,
            localFileName: facts.localFileName,
            contentHash: facts.contentHash,
            sizeBytes: facts.sizeBytes,
            lengthBeats: facts.summary.lengthBeats,
            defaultTempoBpm: facts.summary.defaultTempoBpm,
            primaryKey: facts.summary.primaryKey,
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt,
            tagIDs: tagIDs,
            isFavorite: isFavorite,
            deletedAt: deletedAt,
            // No `?? museScoreMajorVersion` fallback, unlike `rebuilt`: reverting a MusicXML import back to its own
            // file must land on `nil`, not keep the version of the `.mscz` the editor wrote over it.
            museScoreMajorVersion: facts.summary.museScoreMajorVersion,
            sourcePDFFileName: sourcePDFFileName,
            sourcePDFContentHash: sourcePDFContentHash,
            pdfDerivedContentHash: pdfDerivedContentHash,
            pdfConversionFailed: pdfConversionFailed,
            originalFileName: nil,
            originalContentHash: nil,
            originalProvenance: nil,
        )
    }
}
