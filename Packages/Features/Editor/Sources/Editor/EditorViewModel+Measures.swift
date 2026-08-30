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
        appendMeasures(1)
    }

    /// Adds `count` blank bars at the end as ONE edit, so undoing thirty bars is one press rather than thirty.
    ///
    /// A `.composite` runs its members in order against the score as it evolves, which is what makes the indices
    /// here readable: after `i` inserts the score ends at `measureCount + i`, so that is where the next one goes.
    /// Selection and caret are restored around the whole run for the reason `appendMeasure` documents — none of
    /// these inserts shifts an existing bar.
    public func appendMeasures(_ count: Int) {
        guard count > 0 else { return }
        let selection = selectedItem
        let caret = caretItem
        guard apply(intent(insertingAt: measureCount, count: count)) != nil else { return }
        place(selection: selection, caret: caret)
    }

    /// Inserts one blank bar immediately before the target bar — a no-op without a target.
    public func insertMeasureBeforeTarget() {
        insertMeasuresBeforeTarget(1)
    }

    /// Inserts `count` blank bars immediately before the target bar, as one edit — a no-op without a target.
    public func insertMeasuresBeforeTarget(_ count: Int) {
        guard count > 0, let targetMeasureIndex else { return }
        apply(intent(insertingAt: targetMeasureIndex, count: count))
    }

    /// `count` consecutive inserts starting at `start`, as a single intent — the bare intent when there is only
    /// one, so a one-bar edit keeps reading as itself in the undo stack rather than as a composite of one.
    ///
    /// The index advances because the members run against the score as it grows: the bar inserted at `start + i`
    /// lands immediately after the one before it, giving a run rather than a pile at one index.
    private func intent(insertingAt start: Int, count: Int) -> EditIntent {
        let inserts = (0 ..< count).map { EditIntent.insertMeasure(at: start + $0) }
        return inserts.count == 1 ? inserts[0] : .composite(inserts)
    }

    /// Deletes the target bar — a no-op without a target. The engine itself refuses to delete a score's only bar
    /// (`.cannotDeleteOnlyMeasure`), so nothing here needs to special-case a one-measure score either.
    public func deleteTargetMeasure() {
        guard let targetMeasureIndex else { return }
        apply(.deleteMeasure(at: targetMeasureIndex))
    }
}
