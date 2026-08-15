package com.keynumber.folino.reader

import android.app.Application
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.keynumber.folino.editor.EditSessionHost
import com.keynumber.folino.reader.ink.AnnotationToolState
import com.keynumber.folino.reader.pdf.PdfPageSource
import com.keynumber.folino.reader.pdf.PdfPlaybackState
import com.keynumber.folino.reader.swiftjava.FolinoReaderJNI
import io.github.jiyimeta.sheetmusic.BravuraMetricsBuilder
import io.github.jiyimeta.sheetmusic.PartsStavesWireCodec
import io.github.jiyimeta.sheetmusic.PdfScoreHandle
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.SelectionTint
import io.github.jiyimeta.sheetmusic.audio.serialization.SelectionTintCodec
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
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

// A4 page height in millimetres, used as the layout canvas height. The layout WIDTH is no longer
// fixed: it comes from the viewport via [setLayoutWidthMm] so the engine reflows to the real screen
// width (iOS parity). PAGE_WIDTH_MM is only the pre-viewport seed default.
private const val PAGE_WIDTH_MM = 210.0
private const val PAGE_HEIGHT_MM = 297.0

// Debounce window for recomputing the layout after a display-setting change,
// so rapid inspector edits (e.g. dragging staff size) coalesce into one compute.
private const val RECOMPUTE_DEBOUNCE_MS = 120L

// Bound on how long [ReaderViewModel.replaceScoreHandle] will wait for `layoutMutex` before giving up and
// publishing without it (SP4 Task 3 review, Minor 2). Comfortably above any real layout compute, and
// comfortably below Android's ANR window for a main-thread stall, so tripping this at all is itself a signal
// something is wrong — see [ReaderViewModel.replaceScoreHandle]'s own doc.
private const val REPLACE_SCORE_HANDLE_TIMEOUT_MS = 3_000L

private const val TAG = "ReaderViewModel"

/**
 * Inputs to the layout recompute loop, bundled so a single `combine(...)` can carry all five without a
 * generic quintuple. [pdfPlayback] carries the SAME `PdfPlaybackState` the `pdfPlayback` StateFlow does
 * (Task 12) — not a separate derived flag — precisely so there is only one field to keep in sync; see
 * [shouldSkipLayoutRecompute]'s own doc for why `Ready` must suppress this loop. [editRevision] (SP4) is
 * `EditSessionHost.requestRelayout()`'s counter, folded in purely so [startRecomputeLoop] can see it
 * alongside the other four inputs as one value.
 *
 * This `data class`'s auto-generated `equals`/`hashCode` play NO role in driving the loop: `combine` here
 * has no `distinctUntilChanged`, so every upstream emission reaches `mapLatest` regardless of whether the
 * resulting [RecomputeInputs] would compare equal to the previous one. Whether a pass gets to skip
 * RECOMPUTE_DEBOUNCE_MS is a separate, later decision — see [isEditDrivenRecompute].
 */
private data class RecomputeInputs(
    val scoreHandle: Long?,
    val options: LayoutOptions,
    val widthMm: Double?,
    val pdfPlayback: PdfPlaybackState,
    val editRevision: Int,
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
 * Pure decision for [ReaderViewModel.startRecomputeLoop] (SP4 Task 3): true when [editRevision] —
 * `EditSessionHost.requestRelayout()`'s counter — has advanced since [previousEditRevision], the value the
 * loop last COMPLETED a compute for (deliberately not merely attempted; see
 * [ReaderViewModel.previousEditRevision]'s own doc for why a cancelled attempt must not consume it). A
 * `true` result is what lets a pass skip RECOMPUTE_DEBOUNCE_MS: an edit is one discrete user action, not the
 * rapid successive settings changes that debounce exists to coalesce, so it alone earns the skip.
 *
 * This is unrelated to [RecomputeInputs]'s own `equals` — see that class's doc — which plays no part in
 * driving the loop; this is the actual, separate gate that decides the debounce.
 *
 * `internal`, not `private`, so `ReaderEditHostTest` — a JVM test with no Robolectric and no Android
 * `Application` in this module's test source set (see `RecomputeSkipTest`'s own doc for the same
 * constraint) — can pin this decision directly, mirroring how [shouldSkipLayoutRecompute] is `internal` for
 * the same reason.
 */
internal fun isEditDrivenRecompute(editRevision: Int, previousEditRevision: Int): Boolean =
    editRevision != previousEditRevision

/**
 * The `SelectionTintCodec` payload [ReaderViewModel.setEditSelection] hands `nativeEncodeDrawProgram`: [argb] packed
 * as ssm's own `SelectionTintWire` over [ids], which are full-score-addressed `ScoreItemID`s (the same values
 * `nativeEditingHitTest` answers with). An EMPTY [ids] is not a degenerate case — it is how the selection is
 * CLEARED, and ssm documents that an empty selection reproduces `nativeComputeLayout`'s bytes exactly, so tinting
 * and untinting are one call.
 *
 * A one-line wrapper over the generated codec, on purpose. It exists as a named `internal` function, not inlined at
 * the call site, for the same reason [shouldSkipLayoutRecompute] and [isEditDrivenRecompute] do: this module's JVM
 * test source set has no Robolectric and no Android `Application`, so a test cannot construct a [ReaderViewModel] at
 * all — pulling the payload out is what makes the one part of `setEditSelection` that is pure assertable off-device.
 * Never hand-encode this blob: the wire format is ssm's, and a Kotlin second spelling of it would recolor the wrong
 * notes with nothing at runtime noticing.
 */
internal fun selectionTintPayload(ids: List<ScoreItemID>, argb: UInt): ByteArray =
    SelectionTintCodec.encode(SelectionTint(argb = argb, items = ids))

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

class ReaderViewModel(app: Application) : AndroidViewModel(app), EditSessionHost {

    private val _state = MutableStateFlow<ReaderState>(ReaderState.Loading)
    val state: StateFlow<ReaderState> = _state.asStateFlow()

    private val _scoreHandle = MutableStateFlow<Long?>(null)
    val scoreHandle: StateFlow<Long?> = _scoreHandle.asStateFlow()

    // Background OMR-playback readiness of the current PDF (Task 12); `Idle` for a non-PDF score. See
    // [PdfPlaybackState]'s own doc. The Reader's transport reads this (via `nativeCanPlayNow`) to
    // decide whether it may enable, and Task 13's cursor reads a `Ready` handle's geometry.
    private val _pdfPlayback = MutableStateFlow<PdfPlaybackState>(PdfPlaybackState.Idle)
    internal val pdfPlayback: StateFlow<PdfPlaybackState> = _pdfPlayback.asStateFlow()

    // Bumped by [requestRelayout] (EditSessionHost, SP4) once per relayed editing op. The recompute loop
    // folds this in as a fifth `combine` input purely to be told an edit happened — see
    // [startRecomputeLoop]'s `editDriven` check, which is what lets an edit skip RECOMPUTE_DEBOUNCE_MS. Must
    // be declared here, before [init]'s `startRecomputeLoop()` call, like every other flow that loop reads:
    // `viewModelScope.launch` runs eagerly on `Dispatchers.Main.immediate` when already on Main (which the
    // constructor is), so a property declared AFTER `init` would still be uninitialized when the loop first
    // reads it.
    private val _editRevision = MutableStateFlow(0)
    val editRevision: StateFlow<Int> = _editRevision.asStateFlow()

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
    // Seeded from this device's default so the first composed frame does not engrave at the placeholder size and then
    // reflow when the real per-score preferences arrive from the bridge.
    private val _layoutOptions = MutableStateFlow(
        LayoutOptions.DEFAULT.copy(
            staffSize = ReaderDeviceDefaults.staffSize(app),
            honorLayoutBreaks = ReaderDeviceDefaults.honorLayoutBreaks(app),
        ),
    )
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

    // Set once, by [load]'s `.mscz` branch, and never read for its `.raw` value anywhere in this class (SP4
    // Task 3 review, Critical 1 — [pagedProgramAndBreaks] and [horizontalProgram] used to read `handle?.raw`
    // directly, which went stale forever after a resync since `replaceScoreHandle` only ever published
    // `_scoreHandle`; both now read `_scoreHandle.value` instead, which `replaceScoreHandle` keeps current).
    // This field still has to exist, though: `ScoreHandle` releases its native score from a `finalize()`
    // safety net the moment the wrapper becomes unreachable (see `onCleared`'s "Do NOT close `handle`"
    // comment for the established policy this continues), and `_scoreHandle` is a bare `Long` with no such
    // hook — nothing else in this class keeps that Kotlin wrapper object alive. Holding a reference here is
    // what keeps it reachable, and therefore un-finalized, for exactly as long as the class already commits
    // to leaking it. A resync does NOT need to refresh this field to match: `ScoreHandle`'s only
    // raw-wrapping constructor is `internal` to its own module (unreachable from here), and since nothing
    // reads `.raw` off it anymore, the object merely being stale is harmless — it is pinning presence, not
    // its `.raw` value, that this field is for.
    private var handle: ScoreHandle? = null

    // Serializes every native layout call (recompute loop, paged fetch, PiP, page breaks) on this VM.
    // `nativePageBreaks` reads the single-slot `LayoutDocumentCache` populated by the most recent
    // `nativeComputeLayout` on the handle, so a paged fetch must compute-then-read-breaks atomically:
    // without the lock the always-running recompute loop interleaves a compute (different width/options)
    // between the two, clobbering the cache so the breaks no longer match the pages — which blanks the
    // page-mode view (the consistency check drops the data). One mutex around all of them prevents that.
    //
    // SP4 invariant: every critical section under this lock must `withContext(Dispatchers.Default)` BEFORE
    // calling `withLock`, so the acquire, the native call, AND the release all happen already off Main —
    // never acquire while still on Main and release only after hopping back to it. [replaceScoreHandle]
    // (EditSessionHost) takes this lock via `runBlocking` from Main to guarantee no native call is still
    // reading the handle it is about to replace; that wait is a bounded stall ONLY because releasing the
    // lock never depends on Main's `Looper` making progress. If a critical section instead acquired on Main
    // and released after resuming there, [replaceScoreHandle]'s `runBlocking` would deadlock instead of
    // stalling: the compute holding the lock could not resume onto Main to release it while Main is parked
    // inside that `runBlocking`, which — unlike `Dispatchers.Main` — does not pump the platform `Looper`. See
    // [replaceScoreHandle]'s own doc for the full reasoning.
    private val layoutMutex = Mutex()

    // The score id currently loaded into [handle]. Lets [load] stay idempotent across recompositions
    // (LaunchedEffect(scoreId) re-invokes it) while still RELOADING when the Reader is retargeted to a
    // different score in place — playlist auto-advance swaps the rendered scoreId on this same view model.
    // Written only from Main (by [load]), but [openPdf]'s supersession re-check reads it from a
    // `Dispatchers.IO` coroutine just before publishing [pdfPageSource]; `@Volatile` is what makes that read
    // see a retarget that already happened on Main, instead of publishing a renderer + fd nobody will close.
    @Volatile
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

    // The `editRevision` value [startRecomputeLoop]'s `mapLatest` last COMPLETED a compute for — updated
    // ONLY on that block's success path, deliberately not at the top where a pass merely starts (SP4 Task 3
    // review, Minor 1). If a non-edit input (e.g. a viewport resize) cancels an edit-driven pass before its
    // compute lands, and `mapLatest` restarts with the SAME `editRevision`, updating this any earlier would
    // make that restart look like a non-edit change and pay RECOMPUTE_DEBOUNCE_MS the original edit was
    // still owed. Read and written only from inside that block, which is a single-collector coroutine, so no
    // synchronization is needed. See [isEditDrivenRecompute] for the comparison this drives.
    private var previousEditRevision = 0

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
     * Recompute the layout program whenever the score handle, the display options, the viewport-derived
     * layout width, or (SP4) an edit change. `mapLatest` cancels any in-flight compute when a newer
     * [RecomputeInputs] arrives, after a short debounce, so rapid successive changes collapse to a single
     * native call — EXCEPT an edit-driven pass ([requestRelayout] bumping [_editRevision]), which skips the
     * debounce entirely: an edit is one discrete user action, not the rapid inspector dragging
     * RECOMPUTE_DEBOUNCE_MS exists to coalesce, and that delay between a keystroke and the note it produced
     * appearing is exactly the lag the debounce exists to prevent elsewhere.
     *
     * The layout mode (VERTICAL/HORIZONTAL/PAGE) is carried in the options blob
     * as-is; the horizontal/page RENDER surfaces are owned by parallel sessions.
     * This VM only produces the mode-appropriate layout program.
     *
     * Skips entirely per [shouldSkipLayoutRecompute] (Task 12) — see that function's own doc for why a
     * PDF's background-parsed score must never reach the native compute call below.
     *
     * The captured handle is re-verified against `_scoreHandle.value` under [layoutMutex] immediately before
     * the native call, and the pass silently abandons — no error state, since a resync that invalidated it
     * also bumps `_scoreHandle`, itself a `combine` input, so a fresh pass is already on its way — if a
     * resync swapped the handle out from under this pass in that window. See [layoutMutex]'s own doc for why
     * that window exists even with the lock in place, and [replaceScoreHandle]'s own doc for the guarantee
     * this makes possible.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    private fun startRecomputeLoop() {
        viewModelScope.launch {
            combine(
                _scoreHandle,
                _layoutOptions,
                _layoutWidthMm,
                _pdfPlayback,
                _editRevision,
            ) { h, opts, widthMm, pdfPlayback, editRevision ->
                RecomputeInputs(h, opts, widthMm, pdfPlayback, editRevision)
            }
                .mapLatest { (h, opts, widthMm, pdfPlayback, editRevision) ->
                    val isPdfPlaybackReady = pdfPlayback is PdfPlaybackState.Ready
                    if (shouldSkipLayoutRecompute(h, widthMm, isPdfPlaybackReady)) return@mapLatest
                    // Re-derive non-null locals: the predicate above is a plain function call, so the
                    // compiler can't smart-cast `h`/`widthMm` through it even though it already proved
                    // both are non-null whenever this line is reached.
                    val handle = h ?: return@mapLatest
                    val width = widthMm ?: return@mapLatest
                    // See this method's own doc: an edit-driven pass skips the debounce.
                    if (!isEditDrivenRecompute(editRevision, previousEditRevision)) delay(RECOMPUTE_DEBOUNCE_MS)
                    // Dispatch to Default BEFORE acquiring layoutMutex, and let the release happen there too
                    // — see that field's own doc for why this ordering, not the other way round, is what
                    // keeps [replaceScoreHandle]'s `runBlocking` a bounded stall instead of a deadlock.
                    val programBytes = withContext(Dispatchers.Default) {
                        layoutMutex.withLock {
                            // Re-check against the CURRENT published handle, now that the lock is held:
                            // `handle` was captured before this pass crossed `delay` and a dispatcher hop, and
                            // a resync (`replaceScoreHandle`, which publishes under this SAME lock) can free
                            // it in that window even though `mapLatest`'s cancellation is cooperative and may
                            // not have caught up yet — see `layoutMutex`'s own doc. Abandon silently rather
                            // than call native on a handle that may already be freed.
                            if (_scoreHandle.value != handle) return@withLock null
                            SheetMusicJNI.nativeComputeLayout(handle, width, PAGE_HEIGHT_MM, opts.encode())
                        }
                    } ?: return@mapLatest
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
                    // Only mark this revision COMPLETE now — see [previousEditRevision]'s own doc for why an
                    // earlier assignment (e.g. before the native call) would wrongly consume the "still owed"
                    // debounce skip if this pass got cancelled and had to be retried for the same edit.
                    previousEditRevision = editRevision
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
     *
     * **Nothing-playable guard** (found on-device: a "print to PDF" export, e.g. Chrome's `Skia/PDF`,
     * reads as ruled staff lines with no decodable noteheads — the importer still reconstructs the full
     * measure/staff grid, just with nothing to sound). `PdfScoreHandle.load` returning non-null only means
     * the OMR pipeline produced a structurally complete `Score`, not that any of it is audible, so
     * [PdfScoreHandle.playableElementCount] — swift-sheet-music's own count of the chords carrying at least
     * one note that the importer actually reconstructed, computed on the Swift side of the parse where the
     * `Score` already is — is checked via [FolinoReaderJNI.nativeIsPlayableElementCount] BEFORE this parse is ever
     * published. That native call is pure delegation to `Domain.ReaderCapabilities.isPlayableElementCount`
     * — the SAME threshold `Score.hasPlayableContent` applies to iOS's in-process `Score` — so Kotlin never
     * hardcodes its own `count > 0`; the one place that decides "worth playing" is Domain. A count that
     * doesn't clear the threshold takes the exact same [PdfPlaybackState.Unavailable] path as a null parse,
     * including its `scoreId`-vs-[loadedScoreId] supersession guard, and the handle is closed in full
     * (geometry AND score) right there — mirrors the superseded-handle close below: this handle was never
     * published anywhere, so nothing else could possibly be using it.
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
            if (!FolinoReaderJNI.nativeIsPlayableElementCount(parsed.playableElementCount)) {
                // Parsed successfully but yielded nothing worth playing (see the nothing-playable guard in
                // this function's doc). This handle was never published anywhere — unlike the success
                // path below, which only closes on a supersession race — so it can be closed unconditionally,
                // right here on Default: nothing else could possibly hold a reference to it yet.
                parsed.close()
                withContext(Dispatchers.Main.immediate) {
                    // Same supersession guard as the null-parse branch above: don't let this stale
                    // failure clobber a NEWER score's already-published Ready state.
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
        // `_scoreHandle.value`, not `handle?.raw` (SP4 Task 3 review, Critical 1) — `replaceScoreHandle`
        // keeps the former current across a resync; see [handle]'s own field doc for why the latter would
        // go stale forever after one.
        val h = _scoreHandle.value ?: return null
        // Dispatch to Default BEFORE acquiring layoutMutex, and let the release happen there too — see that
        // field's own doc for why this ordering is what keeps `replaceScoreHandle`'s `runBlocking` a bounded
        // stall instead of a deadlock.
        return withContext(Dispatchers.Default) {
            layoutMutex.withLock {
                // Re-check against the CURRENT published handle, now that the lock is held: `h` was captured
                // before this suspended across a dispatch, and a resync (`replaceScoreHandle`, which
                // publishes under this SAME lock) can free it in that window — see `layoutMutex`'s own doc.
                if (_scoreHandle.value != h) return@withLock null
                val optsBytes = layoutOptions.value.encode()
                val programBytes = SheetMusicJNI.nativeComputeLayout(h, pageWidthMm, pageHeightMm, optsBytes)
                if (programBytes.isEmpty()) return@withLock null
                val program = try {
                    DrawProgramReader.decode(programBytes)
                } catch (e: Exception) {
                    return@withLock null
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
        // `_scoreHandle.value`, not `handle?.raw` — see `pagedProgramAndBreaks`'s identical fix and
        // [handle]'s own field doc.
        val h = _scoreHandle.value ?: return null
        val opts = layoutOptions.value.copy(mode = ReaderLayoutMode.HORIZONTAL)
        // Horizontal is a natural single-system layout (no wrapping), so the width arg is irrelevant here;
        // PAGE_WIDTH_MM is just a non-degenerate seed. (PiP also drives this path.)
        // Dispatch to Default BEFORE acquiring layoutMutex, and let the release happen there too — see that
        // field's own doc for why this ordering is what keeps `replaceScoreHandle`'s `runBlocking` a bounded
        // stall instead of a deadlock.
        val bytes = withContext(Dispatchers.Default) {
            layoutMutex.withLock {
                // Re-check against the CURRENT published handle — see `pagedProgramAndBreaks`'s identical
                // guard and `layoutMutex`'s own doc for why this closes the resync TOCTOU window.
                if (_scoreHandle.value != h) return@withLock null
                SheetMusicJNI.nativeComputeLayout(h, PAGE_WIDTH_MM, PAGE_HEIGHT_MM, opts.encode())
            }
        }
        if (bytes == null || bytes.isEmpty()) return null
        return try {
            DrawProgramReader.decode(bytes)
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Recolors [ids] in the CACHED layout (SP4 Task 5). `nativeEncodeDrawProgram` never relayouts — that is the whole
     * reason this entry point exists: selecting a note must not re-engrave the score, both because re-engraving per
     * tap is the cost this avoids and because it would move every rect the caret and the callout are positioned
     * from. An empty [ids] reproduces `nativeComputeLayout`'s bytes exactly, so CLEARING the selection is this same
     * call with an empty list, not a separate path.
     *
     * An empty RESULT is not an error and must not surface as one: it means no layout is cached for this handle yet
     * — the recompute loop has not run for it, or (as of the pinned ssm branch) a relayout an edit overtook refused
     * to cache rather than caching a stale document. Leave the current program alone and wait; the loop is already
     * on its way, and its own publish will carry the selection once [requestRelayout] has driven it.
     *
     * **Handle safety.** This is a fourth native call site on the score handle, so it follows the same two-part
     * pattern [startRecomputeLoop], [pagedProgramAndBreaks] and [horizontalProgram] do — see [layoutMutex]'s own doc
     * for both halves. It dispatches to [Dispatchers.Default] BEFORE acquiring [layoutMutex] (acquiring on Main and
     * releasing after hopping back would turn [replaceScoreHandle]'s `runBlocking` from a bounded stall into a
     * deadlock), and it re-checks `_scoreHandle.value` as the first statement inside `withLock` (the lock alone
     * proves only that no native call is RUNNING, not that none will START with a handle a resync already freed).
     * Without both, an edit session resyncing mid-selection is a use-after-free, not a stale read.
     *
     * **Never clobbers a PDF.** The recompute loop is kept off a PDF by [shouldSkipLayoutRecompute] precisely so a
     * PDF's background-parsed score — which flows through this SAME `_scoreHandle` — can't replace the document's
     * own page pixels with reconstructed notation. This function bypasses that loop entirely, so it carries its own
     * guard: it publishes only when `_state` is ALREADY [ReaderState.Ready], i.e. only when the surface is showing a
     * draw program this call is entitled to replace. That is the direct form of the same rule and is strictly wider
     * than testing `pdfPlayback` — it also declines to overwrite `Loading` and `Error`, neither of which has a
     * program to re-encode either. The check is repeated immediately before the publish, not only on entry: the
     * native call suspends across a dispatcher hop, and [load] can retarget to a PDF in that window. Both the
     * re-check and the write run on Main (`viewModelScope` dispatches `Main.immediate`, and the `withContext` above
     * resumes back onto it) with no suspension point between them, so they cannot tear against [load]'s own
     * Main-thread writes.
     */
    fun setEditSelection(ids: List<ScoreItemID>, argb: UInt) {
        viewModelScope.launch {
            val h = _scoreHandle.value ?: return@launch
            // Cheap early-out so a PDF (or a not-yet-laid-out score) never pays the JNI round trip at all. The
            // authoritative check is the identical one below, after the hop — see this function's own doc.
            if (_state.value !is ReaderState.Ready) return@launch
            val selectionBytes = selectionTintPayload(ids, argb)
            val programBytes = withContext(Dispatchers.Default) {
                layoutMutex.withLock {
                    if (_scoreHandle.value != h) return@withLock null
                    SheetMusicJNI.nativeEncodeDrawProgram(h, selectionBytes)
                }
            } ?: return@launch
            if (programBytes.isEmpty()) return@launch
            val program = try {
                DrawProgramReader.decode(programBytes)
            } catch (e: Exception) {
                // Deliberately NOT ReaderState.Error, unlike the recompute loop's identical decode: that loop owns
                // the score's only program, so it has nothing to fall back on, whereas a selection re-encode that
                // fails leaves a perfectly good untinted program on screen. Blanking the score to report that a
                // highlight didn't apply would be the worse outcome.
                Log.e(TAG, "Could not decode the tinted draw program: ${e.message}")
                return@launch
            }
            if (_state.value !is ReaderState.Ready) return@launch
            _state.value = ReaderState.Ready(program)
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

    // MARK: - EditSessionHost (SP4)
    //
    // The Reader owns the score handle everything else keys off, so it is what implements the edit
    // session's host contract for `EditSessionRelay` (`:FolinoEditorAndroid`). See `EditSessionHost`'s own
    // doc comments for the contract each method below has to uphold.

    override fun scoreHandle(): Long = _scoreHandle.value ?: 0L

    /**
     * The relay calls `nativeReleaseScore(stale)` on the very next line (see `EditSessionHost`'s own doc for
     * the full contract), so every use of the PREVIOUS handle has to be gone before this returns — a render
     * pass queued onto another thread, or a coroutine that will read it on the next frame, is a
     * use-after-free, not a stale read. [startRecomputeLoop]'s `mapLatest` cancels an in-flight compute
     * cooperatively when a newer input arrives, which is NOT synchronous and does not by itself prove the
     * old handle is no longer live — holding [layoutMutex] WHILE RE-CHECKING `_scoreHandle.value` is what
     * proves that, and only for the layout calls: [startRecomputeLoop], [pagedProgramAndBreaks], and
     * [horizontalProgram] all take this lock immediately before their `nativeComputeLayout`/
     * `nativePageBreaks` call and abandon the pass if the handle they captured no longer matches what is
     * published — see [layoutMutex]'s own doc for why the capture and the native call can otherwise straddle
     * a resync even with the lock in place.
     *
     * **This guarantee stops at the layout calls — it is an OPEN GAP, not something this method closes.**
     * `TapToCursor.kt` and `AbBoundaryMarkersOverlay.kt` read `scoreHandle` per-recomposition (a narrow,
     * self-correcting window), but `ReaderAudioViewModel` CACHES the raw handle in its own `scoreHandle:
     * Long?` field (set once by `preparePlayback`) and hands it to the audio engine — that cached value is
     * neither refreshed by this method nor proven safe by anything here. Deciding who owns that lifetime
     * belongs to the task that wires the relay up end to end, where the composition root can see every
     * holder at once; this paragraph exists so that decision isn't made blind.
     *
     * `runBlocking` is what makes taking that lock synchronous from this non-suspending method: a genuine
     * stall of the calling (main) thread while any in-flight `nativeComputeLayout`/`nativePageBreaks` call
     * finishes, rather than an async "settle later." This is a deliberate, already-weighed trade-off, not an
     * oversight — `replaceScoreHandle` only runs on a resync, and SP3's device test measured zero resyncs
     * across a full scripted edit. That figure is SP3's, carried over rather than re-measured on this
     * branch, but nothing here changes what triggers a resync, so it remains the best available evidence
     * that this is a rare recovery path rather than a per-keystroke cost. [REPLACE_SCORE_HANDLE_TIMEOUT_MS]
     * bounds the stall regardless, in case that evidence ever stops holding.
     *
     * That stall is bounded and safe rather than a deadlock ONLY because every [layoutMutex] critical
     * section in this class dispatches to `Dispatchers.Default` BEFORE acquiring the lock and releases it
     * before hopping back to Main — see [layoutMutex]'s own doc for why the reverse ordering (acquire on
     * Main, release only after resuming there) would turn this `runBlocking` into a deadlock instead of a
     * stall: `runBlocking`'s own event loop does not pump the platform `Looper` the way `Dispatchers.Main`
     * needs, so a compute that could only release the lock by resuming onto Main would never get the chance
     * to while Main is parked here.
     *
     * Publishes only [_scoreHandle], not [handle] (the private `ScoreHandle` wrapper) — SP4 Task 3 review,
     * Critical 1. [pagedProgramAndBreaks] and [horizontalProgram] used to read `handle?.raw`, which this
     * method could not keep current: `ScoreHandle`'s only raw-wrapping constructor is `internal` to its own
     * module, unreachable from here. Both functions were switched to read `_scoreHandle.value` instead — see
     * their own docs and [handle]'s own field doc for why that field no longer needs to track a resync at
     * all (nothing reads its `.raw` value anymore; it exists purely to keep the wrapper reachable so its
     * `finalize()` safety net never fires).
     */
    override fun replaceScoreHandle(handle: Long) {
        runBlocking {
            val acquired = withTimeoutOrNull(REPLACE_SCORE_HANDLE_TIMEOUT_MS) {
                layoutMutex.withLock {
                    _scoreHandle.value = handle
                }
            }
            if (acquired == null) {
                // Minor 2 (SP4 Task 3 review): giving up and publishing anyway turns a would-be ANR into a
                // diagnosable report. Tripping this means either the dispatch-before-lock invariant above was
                // violated somewhere, or a native layout call is genuinely still running past this bound —
                // treat this log line as a bug report, not routine output.
                Log.e(
                    TAG,
                    "replaceScoreHandle timed out after ${REPLACE_SCORE_HANDLE_TIMEOUT_MS}ms waiting for " +
                        "layoutMutex; publishing without the lock rather than risking an ANR",
                )
                _scoreHandle.value = handle
            }
        }
    }

    /** Bumps the recompute loop's edit-driven input — see [_editRevision] and [startRecomputeLoop]'s doc. */
    override fun requestRelayout() {
        _editRevision.value += 1
    }

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
