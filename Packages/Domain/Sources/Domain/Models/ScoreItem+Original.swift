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
