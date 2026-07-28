import Domain
import Foundation
import UtilityCore

/// Shared post-import bookkeeping for the two staged hand-off drains: `IncomingShareCoordinator` (folino's own Share
/// Extension, private App Group) and `IncomingScoreCoordinator` (a sibling app's cross-app hand-off, shared App
/// Group). Both run the same `SharedImportCoordinator` and differ only in the analytics `source` they attribute the
/// import to, so the mapping from a `SharedImportResult` onto analytics events and Crashlytics non-fatals lives here
/// instead of being copied per coordinator.
@MainActor
struct ShareImportOutcome {
    let analytics: any Analytics
    let crashReporter: any CrashReporter

    /// Splits the per-token import outcome: one `score_imported` (attributed to `source`) per committed item, and one
    /// `score_import_failed` + non-fatal per genuinely failed file. Duplicate skips are dedupes, not failures, so
    /// they are deliberately not logged.
    func log(_ shared: SharedImportResult, importer: IOSShareImporter, source: String) {
        for id in shared.importedIDs {
            guard let item = importer.itemsByID[id],
                  let format = ScoreFormat.detect(filename: item.localFileName) else { continue }
            analytics.log(.scoreImported(
                format: format,
                source: source,
                isDuplicate: false,
                museScoreMajorVersion: item.museScoreMajorVersion,
            ))
        }
        for skip in shared.skipped {
            guard let failure = Self.failure(for: skip.reason) else { continue }
            crashReporter.record(error: failure.error)
            let format = ScoreFormat.detect(filename: skip.originalName)?.analyticsValue ?? "unknown"
            analytics.log(.scoreImportFailed(format: format, reason: failure.reason))
        }
    }

    /// Maps a skip reason to a stable low-cardinality analytics `reason` (matching the Library file-picker labels)
    /// plus the non-fatal error class. Returns `nil` for `.duplicate`, which is a dedupe rather than a failure.
    private static func failure(for reason: SharedImportSkipReason) -> (reason: String, error: ShareImportFailure)? {
        switch reason {
        case .missingFile: ("file_not_found", .fileNotFound)
        case .parseFailed: ("parse_failed", .parseFailed)
        case .persistenceFailed: ("persistence_failed", .persistenceFailed)
        case .duplicate: nil
        }
    }
}

extension Skip {
    /// Lifts the platform-neutral `SharedImportSkip` the coordinator produces into the iOS-facing `Skip`, whose
    /// reasons carry real `Error` values for the alert/banner layer.
    init(_ shared: SharedImportSkip) {
        let reason: SkipReason = switch shared.reason {
        case .missingFile:
            .unreadable(NSError(
                domain: "ImportExport",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "staged share file was missing"],
            ))
        case .parseFailed:
            .parseFailed(NSError(
                domain: "ImportExport",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "shared score file could not be parsed"],
            ))
        case .persistenceFailed:
            .persistenceFailed(NSError(
                domain: "ImportExport",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "shared score could not be saved"],
            ))
        case let .duplicate(existingID, existingTitle):
            // existingID is `dup.id.rawValue.uuidString` produced by IOSShareImporter, so this UUID parse cannot
            // realistically fail; the fallback is purely defensive (a crash mid-drain would be worse).
            .duplicate(
                existingID: UUID(uuidString: existingID).map(ScoreItemID.init(rawValue:)) ?? ScoreItemID(),
                existingTitle: existingTitle,
            )
        }
        self.init(originalName: shared.originalName, reason: reason)
    }
}
