import Domain
@testable import SettingsLogic
import Testing

@MainActor
struct VersionHistoryViewModelTests {
    private func entries(_ versions: [(Int, Int, Int)]) -> [VersionHistoryEntry] {
        versions.map { VersionHistoryEntry(version: AppVersion($0.0, $0.1, $0.2), descriptions: []) }
    }

    @Test func `zero baseline puts everything in recent`() {
        let all = entries([(1, 5, 0), (1, 2, 0), (1, 0, 0)])
        let vm = VersionHistoryViewModel(entries: all, baseline: .zero, isHistorySplit: false)
        #expect(vm.recentChanges.map(\.version) == all.map(\.version))
        #expect(vm.pastChanges.isEmpty)
        #expect(vm.isHistorySplit == false)
        #expect(vm.isPastChangesShown == false)
    }

    @Test func `non zero baseline splits at baseline`() {
        let all = entries([(1, 5, 0), (1, 3, 0), (1, 2, 0), (1, 0, 0)])
        let vm = VersionHistoryViewModel(
            entries: all, baseline: AppVersion(1, 2, 0), isHistorySplit: true,
        )
        #expect(vm.recentChanges.map(\.version) == [AppVersion(1, 5, 0), AppVersion(1, 3, 0)])
        #expect(vm.pastChanges.map(\.version) == [AppVersion(1, 2, 0), AppVersion(1, 0, 0)])
    }

    @Test func `show more button tap flips flag`() {
        let vm = VersionHistoryViewModel(entries: [], baseline: .zero, isHistorySplit: true)
        #expect(vm.isPastChangesShown == false)
        vm.showMoreButtonDidTap()
        #expect(vm.isPastChangesShown == true)
    }
}
