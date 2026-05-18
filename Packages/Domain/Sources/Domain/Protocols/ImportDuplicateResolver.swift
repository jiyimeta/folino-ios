import Foundation

/// Asks the user (via the App layer) how to handle a duplicate match
/// detected during a share-extension drain. Returning `nil` means the user
/// cancelled — the file is skipped without import.
///
/// `isMultiFile` is `true` when the batch contains more than one file; the
/// App layer uses it to suppress the "Open existing" affordance, which
/// would derail a batch by switching the user to Reader mid-import.
public protocol ImportDuplicateResolver: Sendable {
    @MainActor
    func resolveDuplicate(
        plan: ImportPlan,
        existing: ScoreItem,
        isMultiFile: Bool,
    ) async -> ImportDecision?
}
