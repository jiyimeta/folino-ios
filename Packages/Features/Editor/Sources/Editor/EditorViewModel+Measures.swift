import Domain
import Foundation
import SheetMusicCore

/// Measure structure — append/insert/delete a whole bar, per spec. Every operation routes through the shared
/// `apply(_:)` choke point, so its `rederiveSelection()` is what keeps the selection and caret pointed at a live
/// slot afterwards (or clears them, when the affected bar is gone) — insert-before and delete never re-derive
/// anything themselves. `appendMeasure()` is the one exception: it restores the pre-existing selection/caret
/// instead, since `rederiveSelection()` would otherwise move both onto the bar it just appended (see there).
extension EditorViewModel {
    /// Bar index the measure actions target: the selection's bar, else the caret's, else `nil`. `ScoreItemID`
    /// already carries `measureIndex` for every case it can take here, so no separate accessor is needed.
    public var targetMeasureIndex: Int? {
        selectedItem?.measureIndex ?? caretItem?.measureIndex
    }

    /// The score's bar count on the one staff Folino edits directly — `0` without a score loaded.
    public var measureCount: Int {
        score?.parts.first?.staves.first?.measures.count ?? 0
    }

    /// Adds one blank bar at the end, WITHOUT moving the caret or selection there.
    ///
    /// `InsertMeasure.affectedLocation` names the bar it just inserted, so `apply(_:)`'s own `rederiveSelection()`
    /// would otherwise jump both markers onto the new last bar — likely off-screen on anything but a very short
    /// score, with nothing to reveal it (the host only mirrors `onSelectionChanged`, it doesn't scroll). Appending
    /// shifts no EXISTING bar, so the selection/caret captured before the insert still name exactly the same slots
    /// afterwards — restoring them is a plain `place(selection:caret:)`, not a re-derivation.
    public func appendMeasure() {
        let selection = selectedItem
        let caret = caretItem
        guard apply(.insertMeasure(at: measureCount)) != nil else { return }
        place(selection: selection, caret: caret)
    }

    /// Inserts one blank bar immediately before the target bar — a no-op without a target.
    public func insertMeasureBeforeTarget() {
        guard let targetMeasureIndex else { return }
        apply(.insertMeasure(at: targetMeasureIndex))
    }

    /// Deletes the target bar — a no-op without a target. The engine itself refuses to delete a score's only bar
    /// (`.cannotDeleteOnlyMeasure`), so nothing here needs to special-case a one-measure score either.
    public func deleteTargetMeasure() {
        guard let targetMeasureIndex else { return }
        apply(.deleteMeasure(at: targetMeasureIndex))
    }
}
