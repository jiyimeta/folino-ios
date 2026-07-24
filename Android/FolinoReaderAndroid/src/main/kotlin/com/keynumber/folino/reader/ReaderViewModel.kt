package com.keynumber.folino.reader

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.keynumber.folino.reader.ink.AnnotationToolState
import io.github.jiyimeta.sheetmusic.BravuraMetricsBuilder
import io.github.jiyimeta.sheetmusic.PartsStavesWireCodec
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.compose.draw.DrawProgramReader
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawProgram
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

// A4 page height in millimetres, used as the layout canvas height. The layout WIDTH is no longer
// fixed: it comes from the viewport via [setLayoutWidthMm] so the engine reflows to the real screen
// width (iOS parity). PAGE_WIDTH_MM is only the pre-viewport seed default.
private const val PAGE_WIDTH_MM = 210.0
private const val PAGE_HEIGHT_MM = 297.0

// Debounce window for recomputing the layout after a display-setting change,
// so rapid inspector edits (e.g. dragging staff size) coalesce into one compute.
private const val RECOMPUTE_DEBOUNCE_MS = 120L

/**
 * Two-stack undo/redo history over whole annotation-layer snapshots (`List<T>`), generic over the
 * element type so it is unit-testable with plain `List<String>` layers, without pulling in
 * `DrawingAnchorWire`. Session-scoped: the owning [ReaderViewModel] clears it on rehydrate and on a
 * score retarget, never persisted.
 *
 * [push] records the layer *before* a mutation and always clears the redo stack — a new edit
 * invalidates any previously undone future. Depth is capped at [maxDepth]: once the undo stack
 * exceeds it, the oldest entry is dropped rather than refusing the push.
 */
internal class DrawingHistory<T>(private val maxDepth: Int = 30) {
    private val undoStack = ArrayDeque<List<T>>()
    private val redoStack = ArrayDeque<List<T>>()

    val canUndo: Boolean get() = undoStack.isNotEmpty()
    val canRedo: Boolean get() = redoStack.isNotEmpty()

    fun push(previous: List<T>) {
        undoStack.addLast(previous)
        if (undoStack.size > maxDepth) undoStack.removeFirst()
        redoStack.clear()
    }

    fun undo(current: List<T>): List<T>? {
        if (undoStack.isEmpty()) return null
        val previous = undoStack.removeLast()
        redoStack.addLast(current)
        return previous
    }

    fun redo(current: List<T>): List<T>? {
        if (redoStack.isEmpty()) return null
        val next = redoStack.removeLast()
        undoStack.addLast(current)
        return next
    }

    fun clear() {
        undoStack.clear()
        redoStack.clear()
    }
}

class ReaderViewModel(app: Application) : AndroidViewModel(app) {

    private val _state = MutableStateFlow<ReaderState>(ReaderState.Loading)
    val state: StateFlow<ReaderState> = _state.asStateFlow()

    private val _scoreHandle = MutableStateFlow<Long?>(null)
    val scoreHandle: StateFlow<Long?> = _scoreHandle.asStateFlow()

    // Opening quarter-note BPM (shared Swift `Score.openingQuarterBpm` via JNI), used by
    // the inspector's tempo readout: "♩ = round(bpm × rate)". Defaults to 120.
    private val _openingQuarterBpm = MutableStateFlow(120.0)
    val openingQuarterBpm: StateFlow<Double> = _openingQuarterBpm.asStateFlow()

    private val _parts = MutableStateFlow<List<PartDescriptor>>(emptyList())
    val parts: StateFlow<List<PartDescriptor>> = _parts.asStateFlow()

    // The Reader's display settings, fed from the app layer. SettingsPrefs lives
    // in the `app` module and the Reader library cannot depend on it (that would
    // invert the app -> FolinoReaderAndroid dependency, same boundary the
    // layoutMode plumbing already respects); the app collects the DataStore
    // display flows, assembles a LayoutOptions, and pushes it in via
    // [setLayoutOptions]. The recompute flow keys off this + the score handle.
    private val _layoutOptions = MutableStateFlow(LayoutOptions.DEFAULT)
    val layoutOptions: StateFlow<LayoutOptions> = _layoutOptions.asStateFlow()

    // Viewport-derived layout width (mm) for the wrapping (VERTICAL) layout, pushed via
    // [setLayoutWidthMm] by the Reader's content area. NULL until that viewport has been measured, and
    // the recompute loop WAITS for it rather than laying out at a default: seeding A4 width meant the
    // first layout ran at the wrong width and the score visibly stretched sideways a few hundred ms
    // later when the real width arrived (the right-hand margin collapsing as it reflowed). Waiting
    // costs nothing — a viewport that has no width yet has nothing to show either.
    private val _layoutWidthMm = MutableStateFlow<Double?>(null)
    val layoutWidthMm: StateFlow<Double?> = _layoutWidthMm.asStateFlow()

    // Bumped once per successful layout recompute. Anything positioned against the layout rather than
    // against the score model — the annotation overlay's stroke placement — keys off this: a reflow
    // moves every note within the SAME score handle, so without a signal the placement silently stays
    // where the previous layout put it.
    private val _layoutGeneration = MutableStateFlow(0)
    val layoutGeneration: StateFlow<Int> = _layoutGeneration.asStateFlow()

    private var handle: ScoreHandle? = null

    // Serializes every native layout call (recompute loop, paged fetch, PiP, page breaks) on this VM.
    // `nativePageBreaks` reads the single-slot `LayoutDocumentCache` populated by the most recent
    // `nativeComputeLayout` on the handle, so a paged fetch must compute-then-read-breaks atomically:
    // without the lock the always-running recompute loop interleaves a compute (different width/options)
    // between the two, clobbering the cache so the breaks no longer match the pages — which blanks the
    // page-mode view (the consistency check drops the data). One mutex around all of them prevents that.
    private val layoutMutex = Mutex()

    // The score id currently loaded into [handle]. Lets [load] stay idempotent across recompositions
    // (LaunchedEffect(scoreId) re-invokes it) while still RELOADING when the Reader is retargeted to a
    // different score in place — playlist auto-advance swaps the rendered scoreId on this same view model.
    private var loadedScoreId: String? = null

    init {
        startRecomputeLoop()
    }

    /** Push a new display-settings snapshot in from the app layer; drives a recompute. */
    fun setLayoutOptions(options: LayoutOptions) {
        _layoutOptions.value = options
    }

    /** Push the viewport-derived layout width (mm) in from the render surface; drives a recompute. */
    fun setLayoutWidthMm(mm: Double) {
        if (mm > 0.0) _layoutWidthMm.value = mm
    }

    /**
     * Recompute the layout program whenever the score handle, the display options, or the
     * viewport-derived layout width change. `mapLatest` cancels any in-flight compute when a newer
     * (handle, options, widthMm) triple arrives, after a short debounce, so rapid edits
     * collapse to a single native call.
     *
     * The layout mode (VERTICAL/HORIZONTAL/PAGE) is carried in the options blob
     * as-is; the horizontal/page RENDER surfaces are owned by parallel sessions.
     * This VM only produces the mode-appropriate layout program.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    private fun startRecomputeLoop() {
        viewModelScope.launch {
            combine(_scoreHandle, _layoutOptions, _layoutWidthMm) { h, opts, widthMm ->
                Triple(h, opts, widthMm)
            }
                .mapLatest { (h, opts, widthMm) ->
                    if (h == null || widthMm == null) return@mapLatest
                    delay(RECOMPUTE_DEBOUNCE_MS)
                    val programBytes = layoutMutex.withLock {
                        withContext(Dispatchers.Default) {
                            SheetMusicJNI.nativeComputeLayout(h, widthMm, PAGE_HEIGHT_MM, opts.encode())
                        }
                    }
                    if (programBytes.isEmpty()) {
                        _state.value = ReaderState.Error("Layout produced no output")
                        return@mapLatest
                    }
                    val program = try {
                        DrawProgramReader.decode(programBytes)
                    } catch (e: Exception) {
                        _state.value = ReaderState.Error("Could not render score: ${e.message}")
                        return@mapLatest
                    }
                    _state.value = ReaderState.Ready(program)
                    _layoutGeneration.value += 1
                }
                .collect { }
        }
    }

    /** Resolve the Library's on-disk score file: filesDir/Scores/<id>.mscz */
    private fun scoreFile(scoreId: String): File =
        File(File(getApplication<Application>().filesDir, "Scores"), "$scoreId.mscz")

    /**
     * Parse the score + install metrics + publish the score handle. Does NOT
     * compute the layout itself: the recompute loop (started in init) drives
     * `_state` to Ready once `_scoreHandle` is non-null. Keeps file-not-found
     * and parse-failure error handling here.
     */
    fun load(scoreId: String) {
        // Skip only a redundant reload of the SAME score (recomposition); a different scoreId means the
        // Reader was retargeted in place (playlist auto-advance) and must load the new score so its handle
        // is published — which re-drives the layout recompute and the playback prepare.
        if (scoreId == loadedScoreId) return
        loadedScoreId = scoreId
        // A different score means the undo/redo history belongs to a layer that's about to be replaced;
        // history is session-scoped per score and must not carry entries across the retarget.
        resetHistory()
        // Suspend the layout recompute until the new score's handle is published. The recompute loop
        // skips while the handle is null, so the last Ready(program) keeps rendering unchanged — without
        // this, the incoming score's per-score display options (e.g. staff size) would briefly re-lay-out
        // the OLD handle (a visible "shrink" flash during the playlist auto-advance swap).
        _scoreHandle.value = null
        viewModelScope.launch {
            val app = getApplication<Application>()

            withContext(Dispatchers.Default) {
                val table = BravuraMetricsBuilder.buildTable(app.assets)
                SheetMusicJNI.nativeInstallSMuFLMetrics(table)
            }

            val file = scoreFile(scoreId)
            val bytes = withContext(Dispatchers.IO) {
                if (file.exists()) file.readBytes() else null
            }
            if (bytes == null) {
                _state.value = ReaderState.Error("Score file not found")
                return@launch
            }

            val h = withContext(Dispatchers.Default) { ScoreHandle.load(bytes) }
            if (h == null) {
                _state.value = ReaderState.Error("Could not open score")
                return@launch
            }
            handle = h
            _openingQuarterBpm.value = withContext(Dispatchers.Default) {
                SheetMusicJNI.nativeOpeningQuarterBpm(h.raw)
            }
            _parts.value = withContext(Dispatchers.Default) { loadParts(h.raw) }

            // Publish the handle last: this is what unblocks the recompute loop,
            // which produces the first Ready state via the layout-options flow.
            _scoreHandle.value = h.raw
        }
    }

    /** Fetch + decode the parts/staves descriptor; positional StaffAddress by enumeration index. */
    private fun loadParts(rawHandle: Long): List<PartDescriptor> {
        val bytes = SheetMusicJNI.nativePartsStaves(rawHandle)
        if (bytes.isEmpty()) return emptyList()
        val wire = try {
            PartsStavesWireCodec.decode(bytes)
        } catch (e: Exception) {
            return emptyList()
        }
        return wire.parts.mapIndexed { partIndex, part ->
            PartDescriptor(
                name = part.name,
                staves = part.staves.mapIndexed { staffIndex, staff ->
                    StaffDescriptor(
                        address = StaffAddress(partIndex, staffIndex),
                        defaultClefRawType = staff.defaultClefRawType,
                    )
                },
            )
        }
    }

    /**
     * Multi-page program for page mode AND its matching document-Y page-break offsets, computed
     * atomically under [layoutMutex].
     *
     * `nativePageBreaks` paginates the document that the preceding `nativeComputeLayout` stored in the
     * single-slot `LayoutDocumentCache` for this handle. Both native calls therefore run under one lock
     * with a single options snapshot, so the always-running recompute loop (or any other layout call)
     * cannot clobber the cache between them. Without this the breaks paginate a stale/foreign document
     * (different width or hidden-staff set) and no longer match the page count — which blanked the
     * page-mode view via the caller's `breaks.size == pages.size + 1` consistency gate.
     *
     * Returns the decoded program paired with its breaks, or null on a degenerate / failed compute.
     */
    suspend fun pagedProgramAndBreaks(
        pageWidthMm: Double,
        pageHeightMm: Double,
    ): Pair<DrawProgram, DoubleArray>? {
        val h = handle?.raw ?: return null
        return layoutMutex.withLock {
            withContext(Dispatchers.Default) {
                val optsBytes = layoutOptions.value.encode()
                val programBytes = SheetMusicJNI.nativeComputeLayout(h, pageWidthMm, pageHeightMm, optsBytes)
                if (programBytes.isEmpty()) return@withContext null
                val program = try {
                    DrawProgramReader.decode(programBytes)
                } catch (e: Exception) {
                    return@withContext null
                }
                val breaks = PageBreaksCodec.decode(SheetMusicJNI.nativePageBreaks(h, pageHeightMm, optsBytes))
                program to breaks
            }
        }
    }

    /**
     * One-shot horizontal (single-system) layout program for the Picture-in-Picture surface,
     * independent of the user's current layout mode. Same native call as the recompute loop,
     * with the mode forced to HORIZONTAL in the options blob. Guarded by [layoutMutex] because it
     * also writes the shared `LayoutDocumentCache`.
     */
    suspend fun horizontalProgram(): DrawProgram? {
        val h = handle?.raw ?: return null
        val opts = layoutOptions.value.copy(mode = ReaderLayoutMode.HORIZONTAL)
        // Horizontal is a natural single-system layout (no wrapping), so the width arg is irrelevant here;
        // PAGE_WIDTH_MM is just a non-degenerate seed. (PiP also drives this path.)
        val bytes = layoutMutex.withLock {
            withContext(Dispatchers.Default) {
                SheetMusicJNI.nativeComputeLayout(h, PAGE_WIDTH_MM, PAGE_HEIGHT_MM, opts.encode())
            }
        }
        if (bytes.isEmpty()) return null
        return try {
            DrawProgramReader.decode(bytes)
        } catch (e: Exception) {
            null
        }
    }

    // --- Annotation (Sub-plan E) ---
    private val _annotationMode = MutableStateFlow(false)
    val annotationMode: StateFlow<Boolean> = _annotationMode.asStateFlow()

    // Committed drawings for the active score (the render + save currency; DrawingAnchorWire objects).
    private val _drawings = MutableStateFlow<List<DrawingAnchorWire>>(emptyList())
    val drawings: StateFlow<List<DrawingAnchorWire>> = _drawings.asStateFlow()

    // Session-scoped undo/redo over the annotation layer (cleared on rehydrate and on score retarget —
    // see [onAnnotationOpened] and [load] — never persisted).
    private val history = DrawingHistory<DrawingAnchorWire>()

    // Guards every read-modify-write of the annotation layer as one atomic critical section: the
    // `_drawings` value, the `history` push/undo/redo, and the `_canUndo`/`_canRedo` publish all move
    // together. `addDrawing` is invoked from a per-stroke `Dispatchers.Default` coroutine (off-main JNI
    // capture) racing this VM's main-thread callers (undo/redo taps, whole-stroke erase) — without a lock
    // spanning the whole decide-then-write, a concurrent pen commit can land between an undo/redo's read
    // of `_drawings.value` and its write of the restored layer (TOCTOU), or a history push can observe a
    // layer that a racing writer already moved past. `DrawingHistory` itself is NOT internally
    // synchronized: every access to `history` in this class happens inside `synchronized(layerLock)`, so
    // the single external lock is sufficient and double-locking would just add overhead.
    private val layerLock = Any()

    private val _canUndo = MutableStateFlow(false)
    val canUndo: StateFlow<Boolean> = _canUndo.asStateFlow()

    private val _canRedo = MutableStateFlow(false)
    val canRedo: StateFlow<Boolean> = _canRedo.asStateFlow()

    private val saveController = AnnotationSaveController.build(getApplication<Application>())

    // Tracks the long-lived `loadedDrawings` collector started by [onAnnotationOpened] so a
    // score retarget (playlist auto-advance, mirroring [load]'s loadedScoreId handling) cancels
    // the prior collector instead of stacking a second one on the same ViewModel.
    private var annotationDrawingsJob: Job? = null

    fun toggleAnnotationMode() { _annotationMode.value = !_annotationMode.value }
    fun setAnnotationMode(on: Boolean) { _annotationMode.value = on }

    // Toolbar tool-state selection (pen color/width, eraser width). Plain MutableStateFlow + setter,
    // the same shape as [layoutOptions]/[setLayoutOptions] — no persistence here; Task 9 adds a
    // DataStore-backed restore on top. Held in the VM (not the app layer) so it survives recomposition
    // but resets on process death, which is acceptable for this task.
    private val _toolState = MutableStateFlow(AnnotationToolState())
    val toolState: StateFlow<AnnotationToolState> = _toolState.asStateFlow()

    /** Push a new tool-state selection in from the toolbar. No persistence (Task 9). */
    fun setAnnotationToolState(state: AnnotationToolState) {
        _toolState.value = state
    }

    /** Prime persistence for the score and rehydrate stored drawings into the dry overlay. */
    fun onAnnotationOpened(scoreId: String) {
        annotationDrawingsJob?.cancel()
        annotationDrawingsJob = viewModelScope.launch {
            // `open()` loads synchronously (a DispatchSemaphore bridges the actor coordinator — see
            // AnnotationSaveBridge.open); run it off the main thread so that brief block never touches the UI thread.
            withContext(Dispatchers.IO) { saveController.open(scoreId) }
            saveController.loadedDrawings.collect { wires ->
                // Rehydration is a fresh score's layer, not an undoable step: neither push history (there
                // is no prior in-session layer to undo back to) nor persist (that would echo a save of
                // exactly what was just loaded). Reset history BEFORE the apply, not after: applyDrawings
                // publishes _canUndo/_canRedo from history's state under the same lock, and resetting
                // afterward would leave a window where those StateFlows still reflect the score being
                // replaced.
                resetHistory()
                applyDrawings(pushHistory = false, persist = false) { wires }
            }
        }
    }

    /**
     * Clears the undo/redo history and republishes `_canUndo`/`_canRedo` as one atomic step under
     * [layerLock] — used whenever the in-session history stops applying to the current layer (a
     * rehydrate in [onAnnotationOpened], a score retarget in [load]). Does not touch `_drawings` itself;
     * callers that also need to replace the layer do that via a following [applyDrawings] call.
     */
    private fun resetHistory() {
        synchronized(layerLock) {
            history.clear()
            _canUndo.value = false
            _canRedo.value = false
        }
    }

    /**
     * All annotation-layer mutations funnel through here so the `_drawings` write, the history
     * push, and the `_canUndo`/`_canRedo` publish happen as one atomic critical section under
     * [layerLock] — without it, a per-stroke `Dispatchers.Default` coroutine committing a pen stroke
     * (E8's [addDrawing] call) could interleave with a concurrent mutation and either drop a stroke or
     * push a history entry against a layer a racing writer already moved past. `drawingsChanged` is
     * deliberately called OUTSIDE the lock (it decodes the whole layer across JNI — no need to hold the
     * lock for that), using `updated` captured from inside the lock so the persisted value matches
     * exactly the transition that was just committed.
     */
    private fun applyDrawings(
        pushHistory: Boolean,
        persist: Boolean,
        transform: (List<DrawingAnchorWire>) -> List<DrawingAnchorWire>,
    ) {
        val updated = synchronized(layerLock) {
            val previous = _drawings.value
            val next = transform(previous)
            _drawings.value = next
            if (pushHistory) history.push(previous)
            _canUndo.value = history.canUndo
            _canRedo.value = history.canRedo
            next
        }
        if (persist) saveController.drawingsChanged(updated)
    }

    /** Append a freshly captured drawing, push an undo entry, and (re)arm the debounced save. */
    fun addDrawing(drawing: DrawingAnchorWire) {
        applyDrawings(pushHistory = true, persist = true) { it + drawing }
    }

    /** Remove a drawing (whole-stroke eraser), push an undo entry, and re-arm save. */
    fun removeDrawing(index: Int) {
        applyDrawings(pushHistory = true, persist = true) { l -> l.filterIndexed { i, _ -> i != index } }
    }

    /**
     * Read-only snapshot of the current layer (VM truth), for a caller that needs a stable base to
     * mutate against without triggering any of [applyDrawings]'s side effects — the eraser gesture's
     * BEGIN uses this instead of a separately-collected `drawings` composable state (which can lag the
     * VM by a frame) and instead of pushing a history entry up front (see [eraseInProgress]/
     * [eraseCommitted] for why the push is now deferred to the first ACTUAL change). Reads under
     * [layerLock] so the snapshot can't race a concurrent layer write.
     */
    fun currentDrawings(): List<DrawingAnchorWire> = synchronized(layerLock) { _drawings.value }

    /**
     * Publish the layer mid-erase-drag: the eraser gesture handler (ReaderScreen) calls this once per
     * throttle tick that actually changed the layer (a tick whose `EraseResult.changedIndices` was
     * non-empty — a miss publishes nothing at all, per spec: "changedIndices empty means the gesture did
     * nothing: no save, no undo entry, no phase 2"). [pushHistory] is true only for the FIRST such
     * changing tick of the gesture: [applyDrawings] pushes `_drawings.value` as it stood before this
     * transform, which — since no changing publish preceded it — is exactly the pre-gesture base, so one
     * call yields the one undo entry the whole drag should get. Never persists (the drag isn't done yet
     * — [eraseCommitted] persists the final state); a plain pass-through to the shared [applyDrawings]
     * choke point either way.
     */
    fun eraseInProgress(pushHistory: Boolean, layer: List<DrawingAnchorWire>) {
        applyDrawings(pushHistory = pushHistory, persist = false) { layer }
    }

    /**
     * Publish the erase gesture's final layer at [com.keynumber.folino.reader.ink.ErasePhase.END], but
     * ONLY when the gesture actually changed something (an empty-`changedIndices` whiff publishes
     * nothing — same spec line as [eraseInProgress]). [pushHistory] is true iff no earlier tick of this
     * same gesture already pushed (mirrors [eraseInProgress]'s "first changing tick" rule — if every
     * change happened at END with no changing MOVE before it, END's own publish IS that first tick).
     * Always persists since this is the drag's terminal state — mirrors [addDrawing]/[removeDrawing]'s
     * persist-on-commit, just with the history push made conditional instead of unconditional.
     */
    fun eraseCommitted(pushHistory: Boolean, layer: List<DrawingAnchorWire>) {
        applyDrawings(pushHistory = pushHistory, persist = true) { layer }
    }

    /**
     * Step the layer back one undo entry (a no-op when the undo stack is empty) and persist the result.
     * The read of `_drawings.value`, the `history.undo` decision, and the write of the restored layer
     * all happen inside one [layerLock] section so a concurrent pen commit can't land between "decide"
     * and "write" (the TOCTOU a lock-free version would have).
     */
    fun undoDrawings() {
        val restored = synchronized(layerLock) {
            val current = _drawings.value
            val previous = history.undo(current) ?: return
            _drawings.value = previous
            _canUndo.value = history.canUndo
            _canRedo.value = history.canRedo
            previous
        }
        saveController.drawingsChanged(restored)
    }

    /**
     * Step the layer forward one redo entry (a no-op when the redo stack is empty) and persist the
     * result. Same single-critical-section shape as [undoDrawings].
     */
    fun redoDrawings() {
        val restored = synchronized(layerLock) {
            val current = _drawings.value
            val next = history.redo(current) ?: return
            _drawings.value = next
            _canUndo.value = history.canUndo
            _canRedo.value = history.canRedo
            next
        }
        saveController.drawingsChanged(restored)
    }

    /** Immediate write (call from onPause / score-swap). */
    fun flushAnnotations() { saveController.flush() }

    override fun onCleared() {
        // Best-effort final flush of any pending annotation write (the Reader route's DisposableEffect
        // also flushes on exit; this is belt-and-suspenders).
        saveController.flush()
        // KNOWN FOLLOW-UP — bounded native leak: the annotation save-bridge VM (`saveController`) is held
        // as a plain field, NOT scoped to a ViewModelStore, so its own onCleared -> nativeRelease never
        // fires and the native Swift AnnotationSaveBridge + coordinator + store adapter leak once per
        // Reader entry. `ViewModel.clear()` is internal in androidx.lifecycle, so release can't be
        // triggered from here; the fix is to scope the bridge VM via `AnnotationSaveController.factory()`
        // in the Reader nav route (mirroring `ReaderPreferencesController`). Small per-instance size;
        // deferred as a tracked follow-up (final whole-branch review finding #1).
        //
        // Do NOT close `handle`: the same raw Long is used by the playback
        // engine (which outlives this ViewModel via the bound service).
        // Mirrors the example ScoreViewModel.onCleared rationale.
        super.onCleared()
    }
}
