import Foundation

/// What to do about the original immediately before a write would overwrite the score file.
public enum OriginalCapturePlan: Hashable, Sendable {
    /// Nothing to do: already captured, or this item's file is not one the editor can overwrite.
    case none
    /// Register a file that is already on disk. No bytes are copied, so this cannot fail halfway.
    case adopt(fileName: String, provenance: OriginalProvenance)
    /// Copy the item's current file to `sidecarFileName` first.
    case copy(sidecarFileName: String, provenance: OriginalProvenance)
}

/// Decides that plan. Pure, so iOS and Android cannot disagree about when an original is taken or what it is called.
public enum OriginalCapture {
    /// - Parameter adoptableSourceFileName: the first of `item.adoptableSourceFileNames` the caller found on disk, or
    ///   `nil`. Finding one is stronger evidence than any stored provenance — it is a file the editor has never been
    ///   able to write — so it wins over a `legacyUnknown` pre-stamp.
    public static func plan(
        for item: ScoreItem,
        adoptableSourceFileName: String?,
    ) -> OriginalCapturePlan {
        guard item.originalFileName == nil else { return .none }
        guard let format = ScoreFormat.detect(filename: item.localFileName) else { return .none }
        // An item still displayed as a PDF has no notation to edit, so nothing can overwrite it.
        if format == .pdf { return .none }
        // A non-MuseScore source is never written over: `saveDestination` sends the edit to a sibling `.mscz`, and
        // `LiveScoreFileGateway.saveScore` cannot encode these formats at all.
        if format != .mscx, format != .mscz {
            return .adopt(fileName: item.localFileName, provenance: .importTime)
        }
        if let adoptableSourceFileName {
            return .adopt(fileName: adoptableSourceFileName, provenance: .importTime)
        }
        return .copy(sidecarFileName: item.originalSidecarFileName, provenance: copyProvenance(for: item))
    }

    private static func copyProvenance(for item: ScoreItem) -> OriginalProvenance {
        if let stamped = item.originalProvenance { return stamped }
        return item.pdfOriginState == .converted ? .conversionOutput : .importTime
    }
}
