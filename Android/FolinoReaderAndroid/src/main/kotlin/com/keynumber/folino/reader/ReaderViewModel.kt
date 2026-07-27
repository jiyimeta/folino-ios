package com.keynumber.folino.reader

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.keynumber.folino.reader.ink.AnnotationToolState
import com.keynumber.folino.reader.pdf.PdfPageSource
import com.keynumber.folino.reader.pdf.PdfPlaybackState
import io.github.jiyimeta.sheetmusic.BravuraMetricsBuilder
import io.github.jiyimeta.sheetmusic.PartsStavesWireCodec
import io.github.jiyimeta.sheetmusic.PdfScoreHandle
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
 * Inputs to the layout recompute loop, bundled so a single `combine(...)` can carry all four without a
 * generic `Quad`. [pdfPlayback] carries the SAME `PdfPlaybackState` the `pdfPlayback` StateFlow does
 * (Task 12) — not a separate derived flag — precisely so there is only one field to keep in sync; see
 * [shouldSkipLayoutRecompute]'s own doc for why `Ready` must suppress this loop.
 */
private data class RecomputeInputs(
    val scoreHandle: Long?,
    val options: LayoutOptions,
    val widthMm: Double?,
    val pdfPlayback: PdfPlaybackState,
)

/**
 * Pure predicate for [ReaderViewModel]'s layout recompute loop: true when there is nothing to compute yet
 * ([scoreHandle] or [layoutWidthMm] still null), or when [isPdfPlaybackReady] is true — a PDF's
 * background-parsed score (Task 12) flows through the SAME `scoreHandle` so the existing playback wiring
 * (prepare, mixer, metronome...) picks it up unchanged, but its layout must NOT be computed here: doing so
 * would overwrite `ReaderState.ReadyPdf` with a `Ready(program)`, swapping the PDF's own page pixels for
 * reconstructed notation the user never asked to see. Takes a plain `Boolean` rather than the full
 * `PdfPlaybackState` (the caller derives it via `pdfPlayback is PdfPlaybackState.Ready`, a trivial,
 * obviously-correct one-liner not worth its own test) so this predicate is plain-JVM-testable with no
 * `PdfScoreHandle` instance required (see `RecomputeSkipTest`) — mirrors `shouldAutoFollow` /
 * `nextPlaybackFollowSuspended` in `AutoFollow.kt`, which extract their own gates for the identical
 * reason: this predicate guards the one thing a device check can't easily catch (a one-frame notation
 * flash the instant a PDF's parse succeeds).
 */
internal fun shouldSkipLayoutRecompute(
    scoreHandle: Long?,
    layoutWidthMm: Double?,
    isPdfPlaybackReady: Boolean,
): Boolean = scoreHandle == null || layoutWidthMm == null || isPdfPlaybackReady

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

    // Background OMR-playback readiness of the current PDF (Task 12); `Idle` for a non-PDF score. See
    // [PdfPlaybackState]'s own doc. The Reader's transport reads this (via `nativeCanPlayNow`) to
    // decide whether it may enable, and Task 13's cursor reads a `Ready` handle's geometry.
    private val _pdfPlayback = MutableStateFlow<PdfPlaybackState>(PdfPlaybackState.Idle)
    internal val pdfPlayback: StateFlow<PdfPlaybackState> = _pdfPlayback.asStateFlow()

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

    // The active PDF's page source (Task 6), populated by [openPdf] on a `.pdf` load and closed by
    // [closePdfPageSource] whenever the Reader is retargeted to a different score (see [load]) or this
    // ViewModel is cleared. Null for a non-PDF score. Tasks 7/8's render surfaces read this to fetch
    // and window bitmaps; internal (like [PdfPageSource] itself) and read-only since it is created and
    // torn down only from within this VM. `@Volatile` because [openPdf] writes it from a `Dispatchers.IO`
    // coroutine while Compose call sites read it from the main thread.
    @Volatile
    internal var pdfPageSource: PdfPageSource? = null
        private set

    // The active PDF's background-parsed playback handle (Task 12; mirrors [pdfPageSource]'s shape),
    // set by [parsePdfForPlayback] once `_pdfPlayback` reaches `Ready` and released by
    // [closePdfPlaybackHandle] whenever the Reader is retargeted (see [load]) or this ViewModel is
    // cleared. Both the write (inside [parsePdfForPlayback]'s `Dispatchers.Main.immediate` hop) and every
    // read/clear (`load`, [onCleared]) happen on Main, so `@Volatile` is not load-bearing for THIS field
    // the way it is for [pdfPageSource] (which Compose call sites read from Main while [openPdf] writes
    // it from `Dispatchers.IO`) — kept anyway as cheap insurance against a future caller reading it off
    // Main. `private`, not exposed like [pdfPageSource]: nothing outside this class needs the handle
    // itself, only the `pdfPlayback` StateFlow built from it.
    @Volatile
    private var pdfPlaybackHandle: PdfScoreHandle? = null

    // The coroutine [load] is currently running, cancelled at the top of the NEXT [load] call so a
    // retarget mid-flight (e.g. a playlist auto-advance through several scores in quick succession)
    // can't keep running after it's been superseded. See [load]'s and [openPdf]'s comments for why this
    // alone isn't sufficient to prevent a superseded PDF source from leaking — [openPdf] also re-checks
    // [loadedScoreId] immediately before publishing.
    private var loadJob: Job? = null

    // The background OMR-parse coroutine started by [parsePdfForPlayback], cancelled at the top of the
    // NEXT [load] call for the same reason [loadJob] is: a fast retarget must not let a stale parse for
    // the OLD PDF keep running (and, if it finishes anyway, [parsePdfForPlayback] re-checks
    // [loadedScoreId] immediately before publishing — mirrors [openPdf]'s own supersession guard).
    private var pdfParseJob: Job? = null

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
     *
     * Skips entirely per [shouldSkipLayoutRecompute] (Task 12) — see that function's own doc for why a
     * PDF's background-parsed score must never reach the native compute call below.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    private fun startRecomputeLoop() {
        viewModelScope.launch {
            combine(
                _scoreHandle,
                _layoutOptions,
                _layoutWidthMm,
                _pdfPlayback,
            ) { h, opts, widthMm, pdfPlayback -> RecomputeInputs(h, opts, widthMm, pdfPlayback) }
                .mapLatest { (h, opts, widthMm, pdfPlayback) ->
                    val isPdfPlaybackReady = pdfPlayback is PdfPlaybackState.Ready
                    if (shouldSkipLayoutRecompute(h, widthMm, isPdfPlaybackReady)) return@mapLatest
                    // Re-derive non-null locals: the predicate above is a plain function call, so the
                    // compiler can't smart-cast `h`/`widthMm` through it even though it already proved
                    // both are non-null whenever this line is reached.
                    val handle = h ?: return@mapLatest
                    val width = widthMm ?: return@mapLatest
                    delay(RECOMPUTE_DEBOUNCE_MS)
                    val programBytes = layoutMutex.withLock {
                        withContext(Dispatchers.Default) {
                            SheetMusicJNI.nativeComputeLayout(handle, width, PAGE_HEIGHT_MM, opts.encode())
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

    /**
     * Resolve the Library's on-disk score file from [localFileName] — the record's real file name
     * (Room `local_file_name`, e.g. a PDF import's `<id>.pdf`), threaded down from the App layer
     * (the nav route / retarget call site), which already holds the Library row. The Reader module
     * does no lookup of its own: it has no dependency on the Library module. A blank name (an
     * unknown or since-deleted record) resolves to null so [load] reports "Score file not found"
     * rather than guessing a legacy naming convention that may not match reality.
     */
    private fun scoreFile(localFileName: String): File? {
        if (localFileName.isBlank()) return null
        return File(File(getApplication<Application>().filesDir, "Scores"), localFileName)
    }

    /**
     * Opens [file] as a [PdfPageSource] and publishes its page count and per-page sizes (PDF points)
     * as [ReaderState.ReadyPdf] — the pixels come later, from [pdfPageSource] itself, via Tasks 7/8's
     * render surfaces. The caller ([load]) has already closed any previously held source, so this
     * only needs to clean up the source it just created if building the state fails partway through.
     *
     * [scoreId] is re-checked against [loadedScoreId] immediately before the [pdfPageSource]
     * assignment: [load]'s `loadJob.cancel()` stops a superseded coroutine promptly at its NEXT
     * suspension point, but everything from `PdfPageSource(file)` through the page-size loop above is
     * synchronous with no suspension point of its own, so a retarget that lands mid-loop wouldn't
     * otherwise be noticed until after this source was already published — leaking its file descriptor
     * and native renderer (the newer load's `closePdfPageSource()` call already ran, before this one
     * had anything to close) and briefly exposing the OLD PDF's page geometry under the NEW score.
     * This check closes that window: a superseded source is closed here instead of installed.
     *
     * Returns null on any failure (e.g. a corrupt or unreadable PDF) or if superseded.
     */
    private fun openPdf(file: File, scoreId: String): ReaderState.ReadyPdf? {
        val source = try {
            PdfPageSource(file)
        } catch (_: Exception) {
            return null
        }
        return try {
            val widthsPt = mutableListOf<Double>()
            val heightsPt = mutableListOf<Double>()
            for (i in 0 until source.pageCount) {
                val sizePt = source.pageSizePt(i)
                widthsPt += sizePt.width.toDouble()
                heightsPt += sizePt.height.toDouble()
            }
            if (scoreId != loadedScoreId) {
                source.close()
                return null
            }
            pdfPageSource = source
            ReaderState.ReadyPdf(
                pageCount = source.pageCount,
                pageWidthsPt = widthsPt,
                pageHeightsPt = heightsPt,
            )
        } catch (_: Exception) {
            source.close()
            null
        }
    }

    /** Closes and forgets the active [pdfPageSource], if any. Safe to call when there isn't one. */
    private fun closePdfPageSource() {
        pdfPageSource?.close()
        pdfPageSource = null
    }

    /**
     * Releases the PDF-specific geometry side-car of the currently held [pdfPlaybackHandle], if any,
     * and forgets it. Deliberately does NOT close [PdfScoreHandle.score]: once published, its raw handle
     * is the SAME kind of value the `.mscz` path's [handle] field leaves alone in [onCleared] —
     * `ReaderPlaybackService` (a real bound `MediaSessionService`) may still be holding it for
     * background/PiP playback after this ViewModel is retargeted or cleared, so closing the score here
     * would risk invalidating a still-live native engine out from under it. The geometry handle, in
     * contrast, is used only by this Reader's own on-screen cursor lookups (Task 13) and its native side
     * documents unknown/already-released handles as a no-op, so releasing it unconditionally here is
     * safe. This does mean the score itself is leaked exactly like [handle] already is — an accepted,
     * bounded native leak in this codebase (see [onCleared]'s own comment), not a new one.
     *
     * CAUTION for Tasks 13/14: this leaves the released [PdfScoreHandle] with its own `closed` flag still
     * `false` (only its OWN `close()` sets that). It is harmless today because [_pdfPlayback] is reset to
     * `Idle` before or alongside every call here, so nothing retains a reference to the handle this
     * released. But if a future caller holds on to a `Ready(handle)` value past this point (e.g. a
     * long-lived cursor/tap-to-seek reference) and later calls `handle.close()` on it, that WOULD close
     * the score out from under a still-live playback engine — the exact hazard this method exists to
     * avoid. Any such caller must be retargeted/cleared in lockstep with this ViewModel, not hold its own
     * independent reference across a retarget.
     */
    private fun closePdfPlaybackHandle() {
        pdfPlaybackHandle?.let { SheetMusicJNI.nativeReleasePdfGeometry(it.geometryHandle) }
        pdfPlaybackHandle = null
    }

    /**
     * Parses [file] for playback off the main thread (Task 12): installs the SMuFL metrics table the
     * reconstructed score needs before playback prepares (the `.pdf` branch of [load] deliberately skips
     * this — see its own doc — so it happens here instead), then calls [PdfScoreHandle.load]. On
     * success, publishes the parsed score's raw handle into [_scoreHandle] so the existing
     * playback-prepare path (the recompute loop guards against it — see [shouldSkipLayoutRecompute] — but
     * [ReaderAudioViewModel.preparePlayback], the mixer, metronome, count-in, etc. all key off this same
     * flow) runs exactly as it does for a `.mscz` score, with no further wiring, and loads parts for the
     * mixer the same way [load] does. A parse failure or an empty result publishes
     * [PdfPlaybackState.Unavailable] — never [ReaderState.Error]: the document is already on screen, and
     * an unparseable (e.g. scanned/raster) PDF staying display-only is an acceptable outcome, not a bug.
     *
     * The heavy work — file read, metrics install, `PdfScoreHandle.load`, AND the two JNI calls that read
     * the parsed score (opening BPM, parts/staves) — all stay on [Dispatchers.Default]/[Dispatchers.IO],
     * exactly like the `.mscz` branch of [load] keeps its own identical pair of calls off Main. Only the
     * [scoreId]-vs-[loadedScoreId] check and the plain StateFlow writes hop to
     * [Dispatchers.Main.immediate] — the SAME dispatcher [load]'s retarget-cleanup block runs on. That
     * hop is not incidental: [scoreId] is re-checked immediately before EVERY publish here (including
     * the `Unavailable` one), mirroring [openPdf]'s own supersession guard, but a `Default`-thread check
     * can still race a `Main`-thread [load] call landing between the check and the write — e.g. a parse
     * that reads as "still current" the instant before `load()` resets [loadedScoreId] and [_pdfPlayback]
     * for the NEXT score, whose write would then land right after and clobber that reset. Running the
     * check-and-publish step on `Main.immediate` closes that window outright: `load()`'s reset runs to
     * completion on Main without yielding, this hop genuinely dispatches (the parse coroutine is on
     * `Default`, not already on Main), and neither block has a suspension point of its own — so the two
     * cannot tear on Android's single-threaded main looper. A superseded parse is fully closed — geometry
     * AND score — since nothing else could possibly be using a handle that was never published anywhere.
     */
    private fun parsePdfForPlayback(file: File, scoreId: String) {
        _pdfPlayback.value = PdfPlaybackState.Parsing
        pdfParseJob = viewModelScope.launch(Dispatchers.Default) {
            val app = getApplication<Application>()
            val bytes = try {
                withContext(Dispatchers.IO) { file.readBytes() }
            } catch (_: Exception) {
                null
            }
            val parsed = bytes?.let {
                val table = BravuraMetricsBuilder.buildTable(app.assets)
                SheetMusicJNI.nativeInstallSMuFLMetrics(table)
                try {
                    PdfScoreHandle.load(it)
                } catch (_: Exception) {
                    null
                }
            }
            if (parsed == null) {
                withContext(Dispatchers.Main.immediate) {
                    // Only report Unavailable for the score this parse was actually FOR — a retarget may
                    // already have reset `_pdfPlayback` to `Idle` for a different score, and this must not
                    // clobber that with a stale failure that would leave the NEW score's transport
                    // permanently disabled with no path back.
                    if (scoreId == loadedScoreId) _pdfPlayback.value = PdfPlaybackState.Unavailable
                }
                return@launch
            }
            // Still on Default: read the two values the `.mscz` branch of [load] also computes off Main
            // (`ReaderViewModel.kt`'s own `nativeOpeningQuarterBpm` / `loadParts` calls), so this JNI work
            // never runs on the frame where the transport enables. Safe regardless of supersession: the
            // score handle is still open here — only the Main-side check below can close it.
            val bpm = SheetMusicJNI.nativeOpeningQuarterBpm(parsed.score.raw)
            val parts = loadParts(parsed.score.raw)
            withContext(Dispatchers.Main.immediate) {
                if (scoreId != loadedScoreId) {
                    parsed.close()
                    return@withContext
                }
                pdfPlaybackHandle = parsed
                _openingQuarterBpm.value = bpm
                _parts.value = parts
                // Publish Ready before the raw handle: the recompute loop's `combine` reads BOTH from the
                // same emission once `_scoreHandle` changes, but publishing this first means even a
                // hypothetical intermediate read sees them consistent (see [shouldSkipLayoutRecompute]).
                _pdfPlayback.value = PdfPlaybackState.Ready(parsed)
                _scoreHandle.value = parsed.score.raw
            }
        }
    }

    /**
     * Parse the score + install metrics + publish the score handle. Does NOT
     * compute the layout itself: the recompute loop (started in init) drives
     * `_state` to Ready once `_scoreHandle` is non-null. Keeps file-not-found
     * and parse-failure error handling here.
     *
     * A `.pdf` file takes a separate branch: it publishes [ReaderState.ReadyPdf] via [openPdf] and
     * returns WITHOUT installing SMuFL metrics or calling `ScoreHandle.load` — `_scoreHandle` stays
     * null so the layout recompute loop (which only drives the DrawProgram-based `Ready` state) stays
     * idle. Once the document is on screen, [parsePdfForPlayback] takes over in the background
     * (Task 12) and publishes the parsed score into `_scoreHandle` once ready.
     *
     * [localFileName] is the record's real on-disk file name, supplied by the caller (the App
     * layer, via the nav route or a playlist retarget) rather than looked up here — see
     * [scoreFile]. A blank name (or a name whose file is missing) fails with "Score file not
     * found" instead of crashing.
     */
    fun load(scoreId: String, localFileName: String) {
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
        // A retarget may be leaving a PDF score behind; release its PdfPageSource (and the underlying
        // PdfRenderer + file descriptor) now rather than waiting for onCleared, so a playlist
        // auto-advance through several PDFs in a row doesn't accumulate open descriptors.
        closePdfPageSource()
        // Same idea for a PDF's background-parsed playback (Task 12): reset readiness to Idle so the
        // transport doesn't briefly report the OLD PDF's Ready state under the new score, cancel a still-
        // running parse for the score being left behind, and release the geometry side-car it held.
        _pdfPlayback.value = PdfPlaybackState.Idle
        pdfParseJob?.cancel()
        closePdfPlaybackHandle()
        // Cancel whatever the PREVIOUS load() call is still doing: without this, a fast retarget (e.g.
        // playlist auto-advance through several scores) can leave the old coroutine running concurrently
        // with the new one. This alone doesn't close the whole race for a PDF retarget — see [openPdf]'s
        // doc for the second half of that fix.
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            val app = getApplication<Application>()

            val file = scoreFile(localFileName)
            if (file == null || !withContext(Dispatchers.IO) { file.exists() }) {
                _state.value = ReaderState.Error("Score file not found")
                return@launch
            }

            if (file.extension.equals("pdf", ignoreCase = true)) {
                // No need to read the file into memory here: PdfPageSource (via openPdf) opens it
                // itself and streams pages on demand, which is the whole point of a windowed PDF
                // reader — reading the full bytes just to discard them would defeat that.
                val pdfState = withContext(Dispatchers.IO) { openPdf(file, scoreId) }
                if (pdfState == null) {
                    _state.value = ReaderState.Error("Could not open score")
                    return@launch
                }
                _state.value = pdfState
                // The document is already on screen; parse it for playback in the background (Task 12).
                // Not awaited here: [load]'s own coroutine (this one) is done once the pixels are up, and
                // the parse runs on its own tracked job so a later retarget can cancel it independently.
                parsePdfForPlayback(file, scoreId)
                return@launch
            }

            val bytes = withContext(Dispatchers.IO) { file.readBytes() }

            withContext(Dispatchers.Default) {
                val table = BravuraMetricsBuilder.buildTable(app.assets)
                SheetMusicJNI.nativeInstallSMuFLMetrics(table)
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
     * throttle tick that actually changed the layer (`EraseOutcome.changesLayer` — a split/trim OR a
     * full-cover drop; a miss publishes nothing at all, per spec: "the gesture did nothing: no save, no
     * undo entry, no phase 2"). [pushHistory] is true only for the FIRST such
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
     * ONLY when the gesture actually changed something (a whiff that changed no drawing publishes
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
        closePdfPageSource()
        pdfParseJob?.cancel()
        closePdfPlaybackHandle()
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
        // Mirrors the example ScoreViewModel.onCleared rationale. [closePdfPlaybackHandle] above follows
        // the identical rule for a PDF's parsed score — see its own doc for why it releases only the
        // geometry side-car, not the score.
        super.onCleared()
    }
}
