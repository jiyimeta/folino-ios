import Domain
import EditorCore
import Foundation
import SheetMusicCore

/// The mirror: re-reading everything the core owns into this adapter's `@Observable` state, performing the side
/// effects the core asked for, and firing the two seam callbacks when it says something moved.
///
/// Carved out of `EditorViewModel.swift`, which sits at SwiftLint's `file_length` budget. Every op in
/// `EditorViewModel+Ops.swift` ends in the one call below, which is what guarantees no op can skip a publish.
extension EditorViewModel {
    /// Re-reads everything the core owns, performs the side effects it asked for, and fires the two seam callbacks
    /// when it says something moved.
    ///
    /// **Selection is announced before the score.** That is the shipped order — `apply` used to call
    /// `rederiveSelection()` (which fired `onSelectionChanged` through `place`) before `onScoreChanged` — and it is
    /// not an accident: the Reader host sets `editedScore` and `selection` from these two callbacks, and a selection
    /// arriving before its score names an item the host cannot resolve yet. Keeping the order keeps that working.
    func syncFromCore() {
        let scoreMoved = generation != core.revision
        let selectionMoved = selectionRevision != core.selectionRevision
        generation = core.revision
        appliedEditCount = core.appliedIntentCount
        selectionRevision = core.selectionRevision
        selectedItem = core.selectedItem
        caretItem = core.caretItem
        selection = core.selectedItem.map(ScoreSelection.single) ?? .none
        armedDuration = core.armedDuration
        armedDots = core.armedDots
        isAddToChordArmed = core.isAddToChordArmed
        armedTuplet = core.armedTuplet
        didSaveAsSiblingMSCZ = core.didSaveAsSiblingMSCZ
        hasCapturedOriginal = core.hasCapturedOriginal
        performPendingAudition()
        if selectionMoved {
            onSelectionChanged(selection, caretItem)
        }
        if scoreMoved, let score = core.score {
            onScoreChanged(score)
            scheduleAutosave()
        }
    }
}
