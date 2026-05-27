import Domain
import Observation

@Observable
@MainActor
public final class VersionHistoryViewModel {
    public let isHistorySplit: Bool
    public let recentChanges: [VersionHistoryEntry]
    public let pastChanges: [VersionHistoryEntry]
    public var isPastChangesShown = false

    public init(entries: [VersionHistoryEntry], baseline: AppVersion, isHistorySplit: Bool) {
        self.isHistorySplit = isHistorySplit
        recentChanges = entries.filter { $0.version > baseline }
        pastChanges = entries.filter { $0.version <= baseline }
    }

    public func showMoreButtonDidTap() {
        isPastChangesShown = true
    }
}
