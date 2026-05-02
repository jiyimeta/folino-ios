import Domain
import Foundation

final class FakeScoreFileImporter: ScoreFileImporter, @unchecked Sendable {
    /// Plans queued to be returned by `prepareImport`. Consumed FIFO.
    var preparedPlans: [ImportPlan] = []
    /// Errors queued to be thrown by `prepareImport`. Consumed FIFO; if both
    /// `preparedPlans` and `prepareImportErrors` are non-empty, errors take
    /// precedence on the same call.
    var prepareImportErrors: [DomainError] = []

    /// `commitImport` returns this `ScoreItem` factory invoked with the plan
    /// and decision; tests can capture the call by reading `committed`.
    var commitFactory: (@Sendable (ImportPlan, ImportDecision) -> ScoreItem)?
    var commitImportError: DomainError?

    private(set) var preparedSourceURLs: [URL] = []
    private(set) var committed: [(plan: ImportPlan, decision: ImportDecision)] = []

    func prepareImport(sourceURL: URL) throws -> ImportPlan {
        preparedSourceURLs.append(sourceURL)
        if !prepareImportErrors.isEmpty {
            throw prepareImportErrors.removeFirst()
        }
        guard !preparedPlans.isEmpty else {
            throw DomainError.scoreParseFailed(reason: "FakeScoreFileImporter: no plan queued")
        }
        return preparedPlans.removeFirst()
    }

    func commitImport(_ plan: ImportPlan, decision: ImportDecision) throws -> ScoreItem {
        if let error = commitImportError { throw error }
        committed.append((plan: plan, decision: decision))
        guard let commitFactory else {
            throw DomainError.persistenceFailed(reason: "FakeScoreFileImporter: no commitFactory set")
        }
        return commitFactory(plan, decision)
    }
}
