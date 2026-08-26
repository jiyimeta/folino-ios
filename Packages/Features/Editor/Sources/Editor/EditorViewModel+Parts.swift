import Domain
import Foundation
import SheetMusicCore

/// Instrumentation — the parts a score is written for, add / remove / reorder, as the instruments sheet drives them.
/// Every operation routes through the shared `apply(_:)` choke point, so all three are undoable and all three
/// re-publish the score to the Reader for free; nothing here talks to the engine directly.
///
/// Staff VISIBILITY is deliberately not here: hiding a staff changes what the reader is shown, not what the file
/// says, so it belongs to the Reader's per-score preferences. The sheet reaches it through the two seams the App
/// wires (`isStaffVisible` / `onToggleStaffVisibility`) — this package cannot import Reader.
extension EditorViewModel {
    /// One part as the instruments sheet lists it.
    public struct PartRow: Identifiable, Equatable {
        /// `Part.id`, which the engine keeps stable across reorders — so a dragged row keeps its identity instead of
        /// SwiftUI animating it as a delete plus an insert somewhere else. Positional indices cannot do that job:
        /// every row below a move changes index.
        public let id: String
        /// Where the part sits right now — the index the `.removePart` / `.movePart` intents address it by.
        public let index: Int
        /// What to call it, through `Score.staffDisplayName(at:)` so the sheet, the Reader's inspector and the mixer
        /// all name the same part the same way (instrument long name → track name → "Staff N").
        public let name: String
        /// The part's staves, in order — one visibility toggle each. A piano has two, most instruments one.
        public let staffAddresses: [StaffAddress]
    }

    /// The sheet's rows, derived fresh from the session score each time. Reading `score` registers the `generation`
    /// dependency (see there), which is what makes the list refresh after an add / remove / move / undo.
    public var partRows: [PartRow] {
        guard let score else { return [] }
        return score.parts.enumerated().map { index, part in
            PartRow(
                id: part.id,
                index: index,
                name: score.staffDisplayName(at: StaffAddress(partIndex: index, staffIndexInPart: 0)),
                staffAddresses: part.staves.indices.map {
                    StaffAddress(partIndex: index, staffIndexInPart: $0)
                },
            )
        }
    }

    /// A score must keep at least one part. The engine refuses the last removal itself
    /// (`EditRefusal.Reason.cannotRemoveLastPart`), so this only exists to keep the sheet from OFFERING a delete that
    /// would be refused — the refusal is the authority, this is the affordance.
    public var canRemovePart: Bool {
        (score?.parts.count ?? 0) > 1
    }

    /// Appends a part built from `plan` after the last one. Always at the end: the sheet's own drag handles are how
    /// a part gets somewhere else, and a picker that silently inserted mid-score would be guessing.
    ///
    /// The selection and the caret are put back exactly where they were, the same save/restore `appendMeasure()`
    /// does and for a sharper version of its reason. All three part commands report `affectedLocation` as element 0
    /// of bar 0, which on a real score is a key or time signature — and `SelectionRederivation.item` answers `nil`
    /// for anything that isn't a timed element, so `apply`'s own `rederiveSelection()` falls through to
    /// `select(nil)` and clears BOTH markers. That leaves the input pad inert until the user taps a note again;
    /// adding an instrument shifts no existing part, so the markers still name exactly the same music afterwards.
    public func addPart(_ plan: BlankScoreTemplate.PartPlan) {
        guard let score else { return }
        let selection = selectedItem
        let caret = caretItem
        guard apply(.addPart(plan: plan, at: score.parts.count)) else { return }
        place(selection: selection, caret: caret)
        commitPartEdit()
    }

    /// Removes the part at `index`, with its music. A no-op on a score's only part (see `canRemovePart`).
    ///
    /// Markers restored through the removal's index shift (see `addPart` for why they have to be restored at all).
    /// A marker that was INSIDE the removed part clears — the music it named is gone, and there is nothing to put
    /// it back onto.
    public func removePart(at index: Int) {
        let selection = selectedItem
        let caret = caretItem
        guard apply(.removePart(at: index)) else { return }
        place(
            selection: Self.item(selection, afterRemovingPart: index),
            caret: Self.item(caret, afterRemovingPart: index),
        )
        commitPartEdit()
    }

    /// `List.onMove`'s offsets as a single `(from, to)` part move.
    ///
    /// Two conversions, both load-bearing. Single-item only — this list is a handful of rows and SwiftUI's own drag
    /// hands over exactly one, so `fromOffsets.first` is the whole story rather than a simplification to revisit.
    /// And `toOffset` is a GAP index: it names the slot *before* the row currently sitting there, computed against
    /// the pre-move array. Dragging row 0 below row 1 arrives as `toOffset == 2`, which as a destination part index
    /// is 1 — hence the decrement whenever the destination is below the source. Moving upward needs no adjustment,
    /// because the rows the gap is measured against haven't shifted yet.
    /// Markers ride the permutation, so the caret stays on the SAME music rather than on whatever part happens to
    /// hold that index afterwards — see `addPart` for why they have to be restored at all.
    public func movePart(fromOffsets: IndexSet, toOffset: Int) {
        guard let from = fromOffsets.first else { return }
        let to = toOffset > from ? toOffset - 1 : toOffset
        // A drop that lands where the row already was must not spend an undo step on a no-op.
        guard to != from else { return }
        let selection = selectedItem
        let caret = caretItem
        guard apply(.movePart(from: from, to: to)) else { return }
        place(
            selection: Self.item(selection, afterMovingPart: from, to: to),
            caret: Self.item(caret, afterMovingPart: from, to: to),
        )
        commitPartEdit()
    }

    // MARK: - Settling a part edit against the preferences row

    /// What every part op does once its intent has landed: raise the host's hold, write NOW rather than in two
    /// seconds, and lower the hold again with whatever the migration managed to do.
    ///
    /// The immediate write is the point. On the debounce, the two seconds between a part op and the save that
    /// migrates the row are two seconds in which the score and the row disagree about what a part index means — and
    /// the instruments sheet is still open, one tap away from a staff-visibility toggle that would be written in the
    /// numbering the row has not reached yet. Flushing here shrinks that to the length of one save.
    ///
    /// The hold covers what is left, and is raised and lowered in the SAME call so the two can never come apart: the
    /// settle runs after `flushPendingSave()` whatever that save did — including the cases where `performSave()`
    /// declined to run at all (nothing dirty, a revert in progress) — so a hold can never be left standing.
    /// Overlapping part ops nest, because each op contributes exactly one raise and one lower.
    private func commitPartEdit() {
        unsettledPartEdits += 1
        if unsettledPartEdits == 1 {
            onPartMappingPendingChanged(true)
        }
        let previous = partEditCommitTask
        partEditCommitTask = Task {
            await previous?.value
            lastAppliedPartMapping = nil
            await flushPendingSave()
            let applied = lastAppliedPartMapping
            lastAppliedPartMapping = nil
            unsettledPartEdits = max(0, unsettledPartEdits - 1)
            // Order is load-bearing: the hold lifts BEFORE the host is asked to re-read, so the writes it deferred
            // are free to go through on the same pass rather than being held a second time by their own release.
            if unsettledPartEdits == 0 {
                onPartMappingPendingChanged(false)
            }
            onPartIndicesRemapped(applied)
        }
    }

    // MARK: - Following a marker through a part-index change

    /// Where `item` sits once the part at `removedIndex` is gone: unchanged above it, one part up below it, and
    /// `nil` when it was in the removed part itself.
    static func item(
        _ item: SheetMusicCore.ScoreItemID?, afterRemovingPart removedIndex: Int,
    ) -> SheetMusicCore.ScoreItemID? {
        guard let item else { return nil }
        let part = item.staff.partIndex
        if part == removedIndex {
            return nil
        }
        guard part > removedIndex else { return item }
        return restamping(item, ontoPart: part - 1)
    }

    /// Where `item` sits once the part at `from` has moved to `to` — the same index permutation `MovePart` applies
    /// to the parts array, run over the single address a marker carries. The moved part itself lands on `to`;
    /// everything the move stepped over shifts one place the other way; everything outside the span is untouched.
    static func item(
        _ item: SheetMusicCore.ScoreItemID?, afterMovingPart from: Int, to: Int,
    ) -> SheetMusicCore.ScoreItemID? {
        guard let item else { return nil }
        let part = item.staff.partIndex
        let destination: Int
        if part == from {
            destination = to
        } else if from < to, part > from, part <= to {
            destination = part - 1
        } else if from > to, part >= to, part < from {
            destination = part + 1
        } else {
            return item
        }
        return restamping(item, ontoPart: destination)
    }

    /// Rebuilds `item` on a different PART, leaving the staff-within-part, measure, voice and element indices alone
    /// — a part-index change moves whole parts, it never re-shapes what is inside one. Mirrors
    /// `ReaderEditingHost.restamping(_:onto:)`, which does the same job for the hidden-staff filter. `.clef` passes
    /// through: the editor has no clef-editing UI, so a clef ID never reaches the selection.
    private static func restamping(
        _ item: SheetMusicCore.ScoreItemID, ontoPart partIndex: Int,
    ) -> SheetMusicCore.ScoreItemID {
        let staff = StaffAddress(partIndex: partIndex, staffIndexInPart: item.staff.staffIndexInPart)
        switch item {
        case let .note(id):
            return .note(NoteID(
                staff: staff, measureIndex: id.measureIndex, voiceIndex: id.voiceIndex,
                elementIndex: id.elementIndex, noteIndexInChord: id.noteIndexInChord,
            ))
        case let .rest(id):
            return .rest(RestID(
                staff: staff, measureIndex: id.measureIndex, voiceIndex: id.voiceIndex,
                elementIndex: id.elementIndex,
            ))
        case let .tuplet(id):
            return .tuplet(TupletID(
                staff: staff, measureIndex: id.measureIndex, voiceIndex: id.voiceIndex,
                startElementIndex: id.startElementIndex,
            ))
        case .clef:
            return item
        }
    }
}
