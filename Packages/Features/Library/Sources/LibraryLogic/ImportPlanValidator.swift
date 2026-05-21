import Domain
import Foundation

/// Pure decision: given an `ImportPlan`, should the caller commit
/// directly or stage a duplicate prompt? Extracted from `LibraryStore`
/// for unit-testability and Android-side reuse.
public enum ImportPlanValidator {
    public enum Decision: Equatable, Sendable {
        case commitAsNew
        case promptForDuplicate(existing: ScoreItem)
    }

    public static func decision(for plan: ImportPlan) -> Decision {
        if let existing = plan.duplicates.first {
            return .promptForDuplicate(existing: existing)
        }
        return .commitAsNew
    }
}
