import Domain
import EditorCore
import Foundation
import SheetMusicCore

/// Session lifecycle and history controls: entering and leaving edit mode, and the undo / redo the pad and the
/// system three-finger gestures drive.
///
/// The decisions are the core's — adopting a retained session, what a step does to the score. What lives here is
/// what needs a run loop or a platform: the history store the adapter owns, the flush `endSession` waits on, the
/// part-index migration those two paths owe, and the `UndoManager` trampolines.
///
/// Carved out of `EditorViewModel.swift`, which sits at SwiftLint's `file_length` budget.
extension EditorViewModel {
    public func beginSession(score: Score) {
        // Keyed on the content hash, so a file that changed underneath us gets a fresh session rather than an undo
        // stack addressed to notes that have moved.
        let retained = historyStore.session(for: core.scoreItem.id, contentHash: core.scoreItem.contentHash)
        let adopted = core.beginSession(
            score: score,
            adopting: retained?.session,
            adoptedUndoStepCount: retained?.undoableStepCount ?? 0,
        )
        core.activeVoice = activeVoice
        seedDrumPadLayout()
        // Opening a session is not an edit: match the counter first so `syncFromCore` neither announces a score nor
        // arms the autosave timer for it. The one announcement an open owes the host is the adopted score below.
        generation = core.revision
        syncFromCore()
        // A resumed session opens on the score the PREVIOUS one left, not the one just parsed off disk, so the host
        // has to be told about it — `syncFromCore` only announces a score the revision moved.
        if let adopted {
            onScoreChanged(adopted)
        }
        Task { await reconcileCapturedOriginal() }
    }

    /// Adopts an original that is on disk but missing from the row, and persists the row that names it.
    public func reconcileCapturedOriginal() async {
        guard let adopted = await core.reconcileCapturedOriginal() else { return }
        hasCapturedOriginal = true
        try? await repository.saveScoreItem(adopted)
    }

    /// Flushes any pending autosave and tears the session down.
    public func endSession() async {
        // Captured BEFORE the flush: that flush is a real file write the caller does not wait for, so by the time it
        // returns the user can already be in a new session — which must be neither deposited nor torn down.
        guard let ending = core.session else { return }
        // Captured for the same reason, and at the same moment: the deposit below carries how deep this session's
        // undo stack is, and after the flush the counters it is derived from may already describe a NEW session.
        // Nothing can move the stack in between without dirtying the score, which `shouldRetain` refuses anyway.
        let endingUndoStepCount = core.undoableStepCount
        await flushPendingSave()
        // Last chance at the part-index migration. A failed write inside `performSave` leaves the map unconsumed on
        // the deliberate assumption that a later save will retry it — but the score write itself succeeded, so
        // `isDirty` is `false` and there may never BE a later save. Once this session is dropped the map goes with it
        // and the preferences row and the ink are stranded in the old numbering for good, which is the corruption the
        // whole migration exists to prevent. One extra attempt costs a single load on the only path that has to care;
        // if it fails too, nothing is worse off than before.
        if !ending.isPartMappingIdentity {
            let mapping = await migratePartIndexedState(in: ending, for: core.scoreItem.id)
            onPartIndicesRemapped(mapping)
        }
        if core.shouldRetain(ending) {
            // The depth goes with it: the next entry has to arm one undo per step the adopted stack can still take,
            // and by then this core — the only thing that was counting — is gone.
            historyStore.retain(
                RetainedEditSession(session: ending, undoableStepCount: endingUndoStepCount),
                for: core.scoreItem.id,
                contentHash: core.scoreItem.contentHash,
            )
        }
        core.endSession(ifStillOn: ending)
        syncFromCore()
    }

    public func undo() {
        core.undo()
        syncFromCore()
        settleIfPartMigrationOwed()
    }

    public func redo() {
        core.redo()
        syncFromCore()
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

    /// How many steps the live session can still undo — the whole stack, including what an adopted session brought
    /// with it. `canUndo` is this asked as a yes/no.
    ///
    /// A host that arms something PER undoable step needs the number: macOS registers one `registerSystemUndo`
    /// trampoline each when a session opens, because ⌘Z is the only undo that window has and one trampoline would
    /// offer exactly one step of a retained history.
    public var undoableStepCount: Int {
        _ = generation
        return core.undoableStepCount
    }

    /// Bridges the session's own stacks to the system UndoManager so three-finger swipe gestures work. Each mutation
    /// registers one undo action; performing it re-registers the redo symmetrically. The session remains the source
    /// of truth — the UndoManager holds only trampolines.
    public func registerSystemUndo(with manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { vm in
            vm.undo()
            manager.registerUndo(withTarget: vm) { vm2 in
                vm2.redo()
                vm2.registerSystemUndo(with: manager)
            }
        }
    }

    /// Seeds the pad's drum layout for the session that just opened: the keys the user persisted (the layout is
    /// global) with the voice preset the OPEN FILE implies (that part is per-score).
    ///
    /// Asking the file rather than remembering a preset is what makes the pad agree with the chart in front of you
    /// without being told: a one-voice chart opens on one voice, and the moment any bar uses two the pad opens on
    /// hands-and-feet. A per-key voice the user set by hand survives inside the persisted layout only until a
    /// score implies the other preset — which is the trade the preset makes, and why it is one tap to change.
    private func seedDrumPadLayout() {
        let stored = DrumPadLayoutStore.load()
        guard let staff = core.caretColumn?.staff ?? EditorSessionCore.slot(of: core.caretItem)?.staff,
              let score = core.score
        else {
            core.drumPadLayout = stored
            return
        }
        core.drumPadLayout = DrumVoicePreset.implied(by: score, staff: staff).applied(to: stored)
    }
}
