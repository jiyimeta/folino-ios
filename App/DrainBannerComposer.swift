import ImportExport

/// Composes the user-facing banner string shown after a share-drain completes. Pure formatting only — v1 English,
/// localized later.
enum DrainBannerComposer {
    static func message(for result: DrainResult) -> String? {
        let nonDuplicateSkipped = result.skipped.filter {
            if case .duplicate = $0.reason { false } else { true }
        }
        if result.imported.isEmpty {
            if let dup = result.skipped.first, case let .duplicate(_, title) = dup.reason {
                return "Already in Library: \(title)"
            }
            if let failureName = result.playlistCreateFailure {
                return "Couldn't create playlist \"\(failureName)\""
            }
            if let first = result.skipped.first {
                return "Couldn't import: \(first.originalName)"
            }
            return nil
        }
        if nonDuplicateSkipped.isEmpty {
            let target = result.targetPlaylistName ?? "Library"
            return "\(result.imported.count) added to \(target)"
        }
        guard let firstReason = nonDuplicateSkipped.first?.reason else {
            let target = result.targetPlaylistName ?? "Library"
            return "\(result.imported.count) added to \(target)"
        }
        let total = result.imported.count + nonDuplicateSkipped.count
        let reason = reasonSummary(firstReason)
        let count = nonDuplicateSkipped.count
        return "\(result.imported.count) of \(total) imported. \(reason) for \(count) file(s)"
    }

    private static func reasonSummary(_ reason: SkipReason) -> String {
        switch reason {
        case .unsupportedFormat: "Unsupported format"
        case .unreadable: "Couldn't read"
        case .parseFailed: "Couldn't parse"
        case .persistenceFailed: "Couldn't save"
        case .duplicate: "Already in Library"
        }
    }
}
