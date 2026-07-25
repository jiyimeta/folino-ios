package com.keynumber.folino.reader

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
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
import kotlinx.coroutines.flow.update
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
                // MuseScore <Part><show>: 1 = shown, 0 = authored-hidden.
                isVisibleInScore = part.isVisibleInScore.toInt() != 0,
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

    private val saveController = AnnotationSaveController.build(getApplication<Application>())

    // Tracks the long-lived `loadedDrawings` collector started by [onAnnotationOpened] so a
    // score retarget (playlist auto-advance, mirroring [load]'s loadedScoreId handling) cancels
    // the prior collector instead of stacking a second one on the same ViewModel.
    private var annotationDrawingsJob: Job? = null

    fun toggleAnnotationMode() { _annotationMode.value = !_annotationMode.value }
    fun setAnnotationMode(on: Boolean) { _annotationMode.value = on }

    /** Prime persistence for the score and rehydrate stored drawings into the dry overlay. */
    fun onAnnotationOpened(scoreId: String) {
        annotationDrawingsJob?.cancel()
        annotationDrawingsJob = viewModelScope.launch {
            // `open()` loads synchronously (a DispatchSemaphore bridges the actor coordinator — see
            // AnnotationSaveBridge.open); run it off the main thread so that brief block never touches the UI thread.
            withContext(Dispatchers.IO) { saveController.open(scoreId) }
            saveController.loadedDrawings.collect { wires -> _drawings.value = wires }
        }
    }

    /** Append a freshly captured drawing and (re)arm the debounced save. Atomic: E8 invokes this from
     *  a per-stroke `Dispatchers.Default` coroutine (off-main JNI capture), so concurrent strokes
     *  racing a plain read-modify-write on `_drawings.value` could drop one — `update` avoids that. */
    fun addDrawing(drawing: DrawingAnchorWire) {
        _drawings.update { it + drawing }
        saveController.drawingsChanged(_drawings.value)
    }

    /** Remove a drawing (whole-stroke eraser) and re-arm save. Atomic for the same reason as [addDrawing]. */
    fun removeDrawing(index: Int) {
        _drawings.update { list -> list.filterIndexed { i, _ -> i != index } }
        saveController.drawingsChanged(_drawings.value)
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
