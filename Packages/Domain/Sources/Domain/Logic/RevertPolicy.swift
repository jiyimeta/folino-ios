import Foundation

/// How the original gets back into place.
public enum RevertFilePlan: Hashable, Sendable {
    /// The original is a copy folino took: write it over the item's file, then drop the copy.
    case restoreSidecar(sidecarFileName: String, over: String)
    /// The original is the source file itself, untouched since import: make it the item's file again and delete the
    /// `.mscz` the editor wrote beside it. Nothing is copied, so there is no half-written state to recover from.
    case adoptExistingFile(originalFileName: String, deleting: String)
}

/// What the user is told before a revert.
public struct RevertWarnings: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Ink anchored to the notation is kept, but a stroke written against an edited passage can land elsewhere once
    /// the passage is the original again. Erasing the ink to spare the offset would be the worse failure.
    public static let musicalAnnotationsMayShift = RevertWarnings(rawValue: 1 << 0)
    /// This item predates the feature, so what was captured may already have been edited.
    public static let originalMayNotBeImportTime = RevertWarnings(rawValue: 1 << 1)
}

/// One rule for both platforms, so a destructive action is never softer on one than the other.
public enum RevertPolicy {
    public static func filePlan(for item: ScoreItem) -> RevertFilePlan? {
        guard let originalFileName = item.originalFileName else { return nil }
        // Cannot arise from any state this code writes — a capture that adopts the item's own file is immediately
        // followed by the save that moves `localFileName` to the sibling `.mscz` — but restoring a file over itself
        // and then deleting it would destroy the score, so refuse rather than trust that.
        guard originalFileName != item.localFileName else { return nil }
        if originalFileName == item.originalSidecarFileName {
            return .restoreSidecar(sidecarFileName: originalFileName, over: item.localFileName)
        }
        return .adoptExistingFile(originalFileName: originalFileName, deleting: item.localFileName)
    }

    public static func warnings(for item: ScoreItem, hasMusicalAnnotations: Bool) -> RevertWarnings {
        var warnings: RevertWarnings = []
        if hasMusicalAnnotations { warnings.insert(.musicalAnnotationsMayShift) }
        if item.originalProvenance == .legacyUnknown { warnings.insert(.originalMayNotBeImportTime) }
        return warnings
    }
}
