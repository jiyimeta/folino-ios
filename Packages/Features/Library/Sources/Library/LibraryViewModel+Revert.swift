import Domain
import Foundation

extension LibraryViewModel {
    /// The Library's half of `ScoreInfoEditing`'s revert. Nothing to reload here — the row's own change is what the
    /// list is bound to. A Reader showing this score in an iPad split view keeps its loaded copy until it is
    /// reopened; see the note in the plan's "Known limitations".
    public func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async {
        do {
            let reverted = try await originalStore.revertToOriginal(item, restoringScoreInfo: restoringScoreInfo)
            try await repository.saveScoreItem(reverted)
        } catch {
            currentError = error
        }
    }
}
