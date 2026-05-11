import Domain
import Observation

@Observable
@MainActor
public final class VersionHistoryViewModel {
    let isHistorySplit: Bool
    let recentChanges: [VersionHistoryEntry]
    let pastChanges: [VersionHistoryEntry]
    var isPastChangesShown: Bool = false

    public init(entries: [VersionHistoryEntry], baseline: AppVersion, isHistorySplit: Bool) {
        self.isHistorySplit = isHistorySplit
        recentChanges = entries.filter { $0.version > baseline }
        pastChanges = entries.filter { $0.version <= baseline }
    }

    func showMoreButtonDidTap() {
        isPastChangesShown = true
    }
}
