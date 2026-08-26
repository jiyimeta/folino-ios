import Domain
import Foundation

/// Undo and redo: the session's own history controls, and the bridge that lets the system three-finger gestures
/// drive them. Carved out of `EditorViewModel.swift` (which sits at SwiftLint's `file_length` budget) as a pure
/// move — nothing here changed on the way across.
extension EditorViewModel {
    public var canUndo: Bool {
        session?.canUndo ?? false
    }

    public var canRedo: Bool {
        session?.canRedo ?? false
    }

    public func undo() {
        // `session.undo()` guards `canUndo` and reports an engine failure as `false`, preserving the old contract:
        // a swallowed failure must not fire a false generation bump / onSelectionChanged / onScoreChanged.
        guard let session, session.undo() else { return }
        sessionEditDepth -= 1
        generation += 1
        mutationTicket += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
        settleIfPartMigrationOwed()
    }

    public func redo() {
        guard let session, session.redo() else { return }
        sessionEditDepth += 1
        generation += 1
        mutationTicket += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
        settleIfPartMigrationOwed()
    }

    /// Undo and redo can move the PARTS, and once a save has consumed a mapping they move them away from a baseline
    /// the preferences row has already been written against — undoing a saved removal owes exactly the inverse
    /// migration. Riding the debounce for that would leave the score and the row disagreeing for two seconds with
    /// nothing holding the Reader back, which is the same window `commitPartEdit` exists to close. So an undo /
    /// redo that leaves a migration owed settles the same way a part op does.
    ///
    /// Cheap on the common path: a note edit's undo leaves the parts exactly where the baseline has them, so
    /// `isPartMigrationOwed` is `false` and nothing happens.
    private func settleIfPartMigrationOwed() {
        guard isPartMigrationOwed else { return }
        commitPartEdit()
    }

    /// Bridges ScoreEditSession's own stacks to the system UndoManager so three-finger swipe gestures work. Each
    /// mutation registers one undo action; performing it re-registers the redo symmetrically. The ScoreEditSession
    /// remains the source of truth — the UndoManager holds only trampolines.
    func registerSystemUndo(with manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { vm in
            vm.undo()
            manager.registerUndo(withTarget: vm) { vm2 in
                vm2.redo()
                vm2.registerSystemUndo(with: manager)
            }
        }
    }
}
