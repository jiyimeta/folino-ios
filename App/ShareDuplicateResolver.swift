import Domain
import Foundation
import Observation

@MainActor
@Observable
final class ShareDuplicateResolver: ImportDuplicateResolver {
    var currentPrompt: Prompt?

    @ObservationIgnored
    private var continuation: CheckedContinuation<ImportDecision?, Never>?

    struct Prompt: Identifiable {
        let id = UUID()
        let plan: ImportPlan
        let existing: ScoreItem
        let isMultiFile: Bool
    }

    func resolveDuplicate(
        plan: ImportPlan,
        existing: ScoreItem,
        isMultiFile: Bool,
    ) async -> ImportDecision? {
        await withCheckedContinuation { cont in
            continuation = cont
            currentPrompt = Prompt(plan: plan, existing: existing, isMultiFile: isMultiFile)
        }
    }

    /// Called from the alert buttons. `decision == nil` means user cancelled.
    func respond(_ decision: ImportDecision?) {
        let cont = continuation
        continuation = nil
        currentPrompt = nil
        cont?.resume(returning: decision)
    }
}
