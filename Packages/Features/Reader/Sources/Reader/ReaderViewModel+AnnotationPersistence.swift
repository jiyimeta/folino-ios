import Domain
import Foundation

// MARK: - Annotation persistence (M2 — per-stroke musical anchoring)

extension ReaderViewModel {
    /// Loads any persisted annotation layer for the current score into `annotationDrawings`. Called from `load()` once
    /// the score and preferences are ready. The shared coordinator owns the decode + miss handling (empty on no layer).
    ///
    /// Also the retry point for `isInkReseedPending`: a read that SUCCEEDS proves the model matches the store again,
    /// whatever a failed part-remap re-seed left behind, so it lowers the latch. One that fails leaves the latch where
    /// it stands — the model is still not known to match — while falling back to the same empty set as before, because
    /// this runs on a score swap and keeping the previous score's ink would be worse than showing none.
    func loadAnnotations() async {
        guard let loaded = await annotationCoordinator.reload(scoreID: scoreItem.id) else {
            annotationDrawings = []
            return
        }
        annotationDrawings = loaded
        isInkReseedPending = false
    }

    /// Called by the container on every canvas change with the freshly re-anchored drawings. Updates the in-memory
    /// model immediately (so a re-render projects the live ink, not a stale model) and hands the change to the shared
    /// `AnnotationSaveCoordinator`, which owns the ~0.5 s debounce, the empty→delete policy, and the payload assembly.
    ///
    /// **Dropped outright while a part edit's migration is unsettled**, for the reason `ReaderPreferencesStore.mutate`
    /// queues its writes: during that window this process and the stored layer disagree about what a part index means,
    /// and a capture landing inside it corrupts the ink either way round — stamped in the NEW numbering it gets
    /// migrated a second time, stamped in the OLD numbering it overwrites the migrated layer after the map has been
    /// consumed.
    ///
    /// Dropped rather than QUEUED, unlike the preferences writes, because a capture is not a change — it is the whole
    /// canvas re-anchored against the layout of the moment, and inside this window that layout is showing the ink
    /// through pre-migration anchors, i.e. on the wrong staves. Replaying it would persist exactly that misplacement.
    /// Nor can the genuinely new strokes be salvaged out of it: `AnnotationAnchoring.capture` mints a fresh
    /// `AnnotationID` per stroke on every capture, so there is no identity by which to tell a new stroke from a
    /// re-anchored old one. The migrated layer wins and the re-seed puts it back on screen.
    ///
    /// What that costs is bounded to near nothing in practice: a part edit is driven from the editing chrome's
    /// instruments sheet, which is only reachable inside an edit session — and there the annotation toggle is not on
    /// screen, so `isAnnotating` is false and the canvas takes no touches at all
    /// (`AnnotationCanvasController.update` sets `isUserInteractionEnabled` from it). The captures arriving in this
    /// window are therefore echoes of programmatic re-seeds, not the user's ink. (`isInkDimmed` additionally makes the
    /// ink a translucent reference layer while editing, but only the vertical container sets it, so it is not the
    /// guarantee being relied on here.)
    ///
    /// **Also dropped while `isInkReseedPending` stands** — a part-remap re-seed that could not read the store. The
    /// model is then still holding pre-migration anchors with the mapping already consumed, so the very next capture
    /// would write them over the migrated layer permanently. A separate latch rather than holding the SHARED
    /// `isPartMigrationPending` up: that one also gates the preferences writer, and leaving it raised would strand
    /// that writer for the rest of the session (the round-3 stranded-hold failure mode).
    func annotationDrawingsDidChange(_ drawings: [DrawingAnchor]) {
        guard !isPartMigrationPending(), !isInkReseedPending else { return }
        // A net increase in anchored strokes means new ink was actually committed — the real pencil-usage signal. The
        // canvas's `canvasViewDrawingDidChange` also fires for reflow re-anchoring (same count) and erase (lower
        // count); only a higher count is a fresh commit, so this logs once per committed stroke, never per change tick
        // and never per pixel. Must run before `annotationDrawings` is reassigned below (it is the previous count).
        if drawings.count > annotationDrawings.count {
            recordAnnotationStroke()
        }
        annotationDrawings = drawings
        let scoreID = scoreItem.id
        // The coordinator is an `actor`, so hop off this synchronous @MainActor canvas callback. Keep the task handle
        // so `flushPendingAnnotationSave` can await this registration before flushing — preserving the old guarantee
        // that a score-swap / teardown flush always observes the latest change.
        annotationChangeTask = Task { [annotationCoordinator] in
            await annotationCoordinator.drawingsDidChange(drawings, scoreID: scoreID)
        }
    }

    /// Writes (or deletes) the pending change immediately, bypassing the debounce. Called before `advance` swaps the
    /// score and on VM teardown so no ink is lost mid-transition. Awaits the most recent `drawingsDidChange` hop first
    /// so the flush can't race ahead of an in-flight change registration.
    func flushPendingAnnotationSave() async {
        await annotationChangeTask?.value
        await annotationCoordinator.flush()
    }

    /// Re-seeds the in-memory ink from the layer the Editor has just migrated, and asks the containers to reproject
    /// the canvas from it (`annotationReseedTicket`). Answers whether it actually re-seeded.
    ///
    /// The canvas cannot be left as it is. A part removal changes the score, the containers reproject on that change,
    /// and at that moment the model is still holding pre-migration anchors — so every stroke below the removed part is
    /// drawn over a different instrument's staff. Re-seeding from the store is what puts it right, and it is the store
    /// rather than a second application of the mapping on purpose: one migration, one place it can be wrong.
    ///
    /// A FAILED read re-seeds nothing. `reload` tells a store failure apart from "there is no ink" precisely so this
    /// can refuse: overwriting the live model with an empty set on the strength of one unlucky read would make the
    /// next capture persist that emptiness and delete the score's ink for good.
    ///
    /// But refusing is only half of it — the model is then left holding pre-migration anchors while the hold comes
    /// down and the mapping is consumed, and the next capture is not hypothetical: `reloadPreferencesAfterPartRemap`
    /// ends in `recomputeVisibleScore()`, which moves `document`, which reprojects all three containers and brings
    /// PencilKit's echo of that re-seed straight back here. So a failed read RAISES `isInkReseedPending`, which
    /// refuses captures until a later read succeeds (the next part remap's reload, or `loadAnnotations` on the next
    /// score open). Losing a session's further ink is recoverable; overwriting the migrated layer is not.
    @discardableResult
    func reseedAnnotationsAfterPartRemap() async -> Bool {
        guard let reloaded = await annotationCoordinator.reload(scoreID: scoreItem.id) else {
            isInkReseedPending = true
            return false
        }
        // Only when the layer actually moved. An unmoved one (all-page-anchored ink, or a mapping that renumbered
        // nothing it names) would otherwise force a reproject and the canvas echo that comes with it, for nothing.
        if reloaded != annotationDrawings {
            annotationDrawings = reloaded
            annotationReseedTicket += 1
        }
        isInkReseedPending = false
        return true
    }
}
