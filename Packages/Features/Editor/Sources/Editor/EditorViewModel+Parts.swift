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
    public func addPart(_ plan: BlankScoreTemplate.PartPlan) {
        guard let score else { return }
        apply(.addPart(plan: plan, at: score.parts.count))
    }

    /// Removes the part at `index`, with its music. A no-op on a score's only part (see `canRemovePart`).
    public func removePart(at index: Int) {
        apply(.removePart(at: index))
    }

    /// `List.onMove`'s offsets as a single `(from, to)` part move.
    ///
    /// Two conversions, both load-bearing. Single-item only — this list is a handful of rows and SwiftUI's own drag
    /// hands over exactly one, so `fromOffsets.first` is the whole story rather than a simplification to revisit.
    /// And `toOffset` is a GAP index: it names the slot *before* the row currently sitting there, computed against
    /// the pre-move array. Dragging row 0 below row 1 arrives as `toOffset == 2`, which as a destination part index
    /// is 1 — hence the decrement whenever the destination is below the source. Moving upward needs no adjustment,
    /// because the rows the gap is measured against haven't shifted yet.
    public func movePart(fromOffsets: IndexSet, toOffset: Int) {
        guard let from = fromOffsets.first else { return }
        let to = toOffset > from ? toOffset - 1 : toOffset
        // A drop that lands where the row already was must not spend an undo step on a no-op.
        guard to != from else { return }
        apply(.movePart(from: from, to: to))
    }
}
