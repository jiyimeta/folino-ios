package com.keynumber.folino.reader.ink

import androidx.compose.ui.geometry.Offset
import com.keynumber.folino.reader.DrawingAnchorWire
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Sequences one BEGIN→MOVE*→END partial-eraser gesture against [AnnotationEraseController], including the
 * generation/history-push bookkeeping that collapses a whole drag into at most one undo entry even under a
 * fast scrub-lift-scrub. Extracted from an inline handler `ReaderScreen` originally built for the musical
 * surfaces only (Task 8) so a PDF surface (Task 11: page-anchored erase) drives the identical state machine
 * against [AnnotationEraseController]'s now anchor-kind-generic `applyErase`/`reanchor` instead of
 * re-deriving this bookkeeping's hazards a second time — see the field docs below for exactly what each one
 * defends against.
 *
 * One instance per surface (construct via `remember`) — an in-flight drag has no reason to survive a
 * layout-mode switch, unlike [AnnotationSurfaceState.inkHandoff] (which IS shared across a switch).
 * Internally owns its own single-parallelism dispatcher rather than taking one as a constructor
 * parameter — the FIFO-on-one-thread requirement (`applyErase`'s own doc: a slow MOVE tick must not finish
 * AFTER END and publish a stale result on top of it) is this class's own correctness contract, not
 * something every call site should have to reconstruct correctly.
 */
internal class EraseGestureController {
    // Single-parallelism view of Dispatchers.Default: strict FIFO EXECUTION (not just FIFO dispatch) on the
    // same underlying thread pool, so END always runs after every MOVE queued before it — see the class doc.
    private val eraseDispatcher = Dispatchers.Default.limitedParallelism(1)

    // `eraseWorkingAtBegin` is snapshotted ONCE at BEGIN and never reassigned during the drag; every
    // MOVE/END tick re-applies the FULL accumulated `erasePath` against this SAME BEGIN snapshot rather
    // than chaining tick-to-tick onto the previous tick's own output — re-cutting a fixed base with the
    // same path is stable across a throttle's repeated ticks, whereas chaining forward would compound any
    // per-tick geometry drift. `erasePath` accumulates the whole gesture's contiguous polyline per
    // `AnnotationWetOverlay`'s BEGIN/MOVE/END emission contract (see its class doc).
    private var eraseWorkingAtBegin: List<DrawingAnchorWire> = emptyList()
    private var erasePath: List<Offset> = emptyList()

    // True from a processed BEGIN through its matching END's publish. Without this, a stray MOVE/END with
    // no preceding BEGIN on THIS instance (there shouldn't be one, but nothing enforces it structurally)
    // would run against state left over from a previous drag, corrupting the layer with a mutation no undo
    // entry covers.
    private var eraseArmed = false

    // Bumped by every BEGIN. `eraseArmed` alone isn't enough to protect a gesture's OWN coroutines from a
    // NEWER gesture: END's disarm runs inside its async `withContext(Main)` publish, which is queued behind
    // `eraseDispatcher` — on a fast scrub-lift-scrub, gesture N's END can drain AFTER N+1's BEGIN has
    // already re-armed, so an unconditional disarm at N's END would disarm N+1 mid-drag. Each MOVE/END
    // coroutine captures `eraseGeneration` on Main at launch time and compares it against the LIVE value in
    // its Main-thread publish: a mismatch means a newer gesture has since started, so that coroutine's
    // result is superseded and must not touch the layer OR the armed flag.
    private var eraseGeneration = 0

    // Whether THIS gesture has already pushed its one undo entry. Starts false at every BEGIN — BEGIN
    // itself does NOT push a history entry (a stray tap on blank space, or a scrub that never reaches a
    // stroke, must not push a dead undo entry or clear the redo stack). The first MOVE/END tick whose
    // outcome actually changes something flips this to true; every later changing tick of the same gesture
    // passes `pushHistory = false` — so a whole drag that changes anything collapses to exactly one undo
    // entry, while a drag that changes nothing pushes zero.
    private var eraseHistoryPushed = false

    /**
     * Handle one phase of the gesture.
     *
     * @param scoreHandle Passed straight through to [AnnotationEraseController.reanchor]'s musical
     *   recapture branch; `null` for a PDF surface (page-anchor fragments never need it — see that
     *   function's own doc for why a page anchor's Phase 2 is a no-op).
     * @param currentDrawings The erase base — VM truth, not a possibly-stale composed snapshot. Read only
     *   at BEGIN.
     * @param resolveDisplayTransforms [AnnotationEraseController.applyErase]/[AnnotationEraseController
     *   .reanchor]'s own injected transform resolver — the SAME one the caller's dry overlay uses, so the
     *   hit test runs in the exact display space the user saw the ink in.
     * @param releaseWetRetention Retires the wet layer's retained copies before publishing (a not-yet-
     *   painted wet stroke must not keep rendering once the layer under it changes) — normally
     *   `annotation.inkHandoff::releaseAll`.
     * @param onInProgress / @param onCommitted Mirror `ReaderViewModel.eraseInProgress`/`eraseCommitted`'s
     *   `(pushHistory, drawings)` shape.
     */
    fun handle(
        scope: CoroutineScope,
        phase: ErasePhase,
        pathMm: List<Offset>,
        radiusMm: Float,
        scoreHandle: Long?,
        currentDrawings: () -> List<DrawingAnchorWire>,
        resolveDisplayTransforms: (List<DrawingAnchorWire>) -> ByteArray,
        releaseWetRetention: () -> Unit,
        onInProgress: (pushHistory: Boolean, drawings: List<DrawingAnchorWire>) -> Unit,
        onCommitted: (pushHistory: Boolean, drawings: List<DrawingAnchorWire>) -> Unit,
    ) {
        when (phase) {
            ErasePhase.BEGIN -> {
                eraseArmed = true
                // Bump so any in-flight coroutine from a PREVIOUS gesture (still draining
                // `eraseDispatcher`, see `eraseGeneration`'s doc) is recognizable as superseded the
                // moment it reaches its Main publish.
                eraseGeneration++
                eraseHistoryPushed = false
                eraseWorkingAtBegin = currentDrawings()
                erasePath = pathMm
            }
            ErasePhase.MOVE -> {
                if (!eraseArmed) return
                erasePath = erasePath + pathMm
                val snapshot = eraseWorkingAtBegin
                val path = erasePath
                // Captured on Main at launch — compared against the LIVE `eraseGeneration` in the Main
                // publish below.
                val gen = eraseGeneration
                scope.launch(eraseDispatcher) {
                    val outcome = AnnotationEraseController.applyErase(
                        snapshot, resolveDisplayTransforms, path, radiusMm,
                    )
                    // Publish only on an ACTUAL change: null = native miss, and a cut that hit nothing
                    // leaves the layer / undo history / save alone. "Changed" must count DROPS too, not
                    // just fragments — a fully-covered stroke is dropped with an empty `changedIndices`,
                    // so gating on `changedIndices` alone would silently discard a pure-drop gesture.
                    if (outcome != null && outcome.changesLayer(snapshot.size)) {
                        withContext(Dispatchers.Main) {
                            if (gen == eraseGeneration) {
                                val push = !eraseHistoryPushed
                                if (push) eraseHistoryPushed = true
                                releaseWetRetention()
                                onInProgress(push, outcome.drawings)
                            }
                        }
                    }
                }
            }
            ErasePhase.END -> {
                if (!eraseArmed) return
                erasePath = erasePath + pathMm
                val snapshot = eraseWorkingAtBegin
                val path = erasePath
                val gen = eraseGeneration
                scope.launch(eraseDispatcher) {
                    val outcome = AnnotationEraseController.applyErase(
                        snapshot, resolveDisplayTransforms, path, radiusMm,
                    )
                    // Same whiff rule as MOVE. Re-anchoring only applies to fragments (there is nothing to
                    // re-anchor in a pure drop), so a drop-only cut commits `outcome.drawings` verbatim.
                    val committed = if (outcome != null && outcome.changesLayer(snapshot.size)) {
                        if (outcome.changedIndices.isNotEmpty()) {
                            AnnotationEraseController.reanchor(
                                outcome.drawings, outcome.changedIndices, resolveDisplayTransforms, scoreHandle,
                            )
                        } else {
                            outcome.drawings
                        }
                    } else {
                        null
                    }
                    withContext(Dispatchers.Main) {
                        if (gen == eraseGeneration) {
                            if (committed != null) {
                                val push = !eraseHistoryPushed
                                if (push) eraseHistoryPushed = true
                                releaseWetRetention()
                                onCommitted(push, committed)
                            }
                            // THIS gesture is over regardless of outcome — a whole-gesture whiff (native
                            // miss, or a cut that never touched anything) publishes nothing, per spec: no
                            // save, no undo entry, no phase 2, but still disarms.
                            eraseArmed = false
                        }
                        // If superseded (gen != eraseGeneration): silently no-op. Its erased fragments were
                        // already published in-progress by its own MOVE ticks (the next gesture builds on
                        // them), but its reanchor is dropped — those fragments stay on their inherited
                        // anchor until re-erased. Narrow, self-healing, requires a sub-second scrub-lift-
                        // scrub on a large layer (same accepted residual the original handler documented).
                    }
                }
            }
        }
    }
}
