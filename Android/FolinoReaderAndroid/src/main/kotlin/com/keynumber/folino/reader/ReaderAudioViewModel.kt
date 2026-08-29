package com.keynumber.folino.reader

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.jiyimeta.sheetmusic.ScoreMetadata
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.ClefAnchor
import io.github.jiyimeta.sheetmusic.audio.model.LoopRange
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.model.RehearsalMarkEntry
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.serialization.RehearsalMarkCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlin.math.log2

@OptIn(ExperimentalCoroutinesApi::class)
class ReaderAudioViewModel(application: Application) : AndroidViewModel(application) {

    private val _engine = MutableStateFlow<AndroidPlaybackEngine?>(null)
    val engine: StateFlow<AndroidPlaybackEngine?> = _engine.asStateFlow()

    @Volatile
    private var serviceBinder: ReaderPlaybackService.LocalBinder? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val local = binder as ReaderPlaybackService.LocalBinder
            serviceBinder = local
            _engine.value = local.engine
            // A soundfont hot-swap re-prepares the engine and resets these session-only prefs (the engine
            // can't report them back), so re-push them after the swap rebuilds the synth.
            local.setOnSoundfontReloaded {
                local.engine.setMasterVolume(_masterVolume.value)
                local.engine.setMetronomeEnabled(_metronomeEnabled.value)
            }
        }
        override fun onServiceDisconnected(name: ComponentName) {
            serviceBinder?.setOnSoundfontReloaded(null)
            serviceBinder = null
            _engine.value = null
        }
    }

    init {
        val intent = Intent(application, ReaderPlaybackService::class.java)
        application.startService(intent)
        application.bindService(intent, connection, Context.BIND_AUTO_CREATE)
    }

    val state: StateFlow<PlaybackState> = _engine
        .flatMapLatest { it?.state ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, PlaybackState.STOPPED)

    val currentCursor: StateFlow<ScoreCursor?> = _engine
        .flatMapLatest { it?.currentCursor ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    /**
     * Lookahead anchor for vertical-mode auto-scroll: the cursor [SCROLL_LOOKAHEAD_BEATS] quarter-note
     * beats ahead of the live cursor, via the shared ssm `Score.cursor(advancedByBeats:from:)` (JNI).
     * Non-null ONLY while playing; the Reader falls back to keep-in-view when null. Mirrors iOS
     * `ReaderPlaybackSession.scrollAnchorCursor`.
     *
     * No scrub/drag-seek guard is needed on Android — this VM has no seek-bar drag state; the iOS
     * `scrubCursor` equivalent does not exist here.
     */
    val scrollAnchorCursor: StateFlow<ScoreCursor?> =
        _engine.flatMapLatest { engine ->
            if (engine == null) flowOf(null)
            else combine(engine.state, engine.currentCursor) { state, cursor ->
                val handle = scoreHandle
                if (state != PlaybackState.PLAYING || cursor == null || handle == null) {
                    null
                } else {
                    ScoreCursorCodec.decode(
                        SheetMusicJNI.nativeCursorAdvancedByBeats(
                            handle, ScoreCursorCodec.encode(cursor), SCROLL_LOOKAHEAD_BEATS,
                        ),
                    )
                }
            }
        }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    /**
     * Lookahead anchor for PAGE mode: the cursor [PAGE_LOOKAHEAD_BEATS] beats ahead of the live cursor,
     * via the shared ssm `Score.cursor(advancedByBeats:from:)` (JNI). Non-null ONLY while playing; page
     * mode falls back to the real cursor when null. Mirrors iOS `ReaderPlaybackSession.pageAnchorCursor`.
     */
    val pageAnchorCursor: StateFlow<ScoreCursor?> =
        _engine.flatMapLatest { engine ->
            if (engine == null) flowOf(null)
            else combine(engine.state, engine.currentCursor) { state, cursor ->
                val handle = scoreHandle
                if (state != PlaybackState.PLAYING || cursor == null || handle == null) {
                    null
                } else {
                    ScoreCursorCodec.decode(
                        SheetMusicJNI.nativeCursorAdvancedByBeats(
                            handle, ScoreCursorCodec.encode(cursor), PAGE_LOOKAHEAD_BEATS,
                        ),
                    )
                }
            }
        }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    // Mirrors iOS `ReaderPlaybackSession.hasLoadedIntoPlayback`: true once a score is prepared into the
    // engine, cleared at natural end (below) and on teardown. Distinguishes the engine's natural
    // end-of-score cursor nil from a teardown nil, so auto-advance fires only at a true end.
    @Volatile
    private var hasLoadedIntoPlayback = false

    // One-shot end-of-score signal. The Reader collects this to run the playlist auto-advance decision.
    // No replay; buffered by 1 so an emit without an active collector is not dropped.
    private val _onReachedEnd = kotlinx.coroutines.flow.MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val onReachedEnd: kotlinx.coroutines.flow.SharedFlow<Unit> =
        _onReachedEnd.asSharedFlow()

    init {
        // End-of-score = the engine nils the cursor while a score is loaded (iOS parity). The flag is
        // cleared here before emitting so a subsequent teardown/re-prepare nil cannot re-fire advance.
        // Placed after the properties it reads (currentCursor / hasLoadedIntoPlayback / _onReachedEnd)
        // so they are initialized before this init block runs.
        viewModelScope.launch {
            currentCursor.collect { cursor ->
                if (cursor == null && hasLoadedIntoPlayback) {
                    hasLoadedIntoPlayback = false
                    _onReachedEnd.tryEmit(Unit)
                }
            }
        }
    }

    // ── Playback-follow suspension ──────────────────────────
    // Runtime, session-scoped suspension of playback cursor auto-follow (auto-scroll / auto-page-turn).
    // SET when the user takes manual control of the viewport — scroll, pinch-zoom, or page-turn — WHILE
    // playing; CLEARED only when playback (re)starts (the pause→play transition, observed below) or the
    // cursor is set manually (tap-seek / measure-step / seek bar / rehearsal-mark / jump-to-start).
    // Independent of the persistent auto-follow opt-out (`SettingsPrefs.autoFollow`): this lets the reader
    // look ahead / back during playback without the page yanking to the playhead on the next cursor tick.
    // All three score surfaces (vertical / horizontal / page) read it to gate their auto-follow. Sticky —
    // it does NOT clear merely because the gesture ended. Mirrors iOS
    // `ReaderPlaybackSession.isPlaybackFollowSuspended`.
    private val _isPlaybackFollowSuspended = MutableStateFlow(false)
    val isPlaybackFollowSuspended: StateFlow<Boolean> = _isPlaybackFollowSuspended.asStateFlow()

    init {
        // Resuming playback re-arms auto-follow: clear any manual-viewport suspension left from the
        // previous play run when the engine (re)enters PLAYING. `state` is a conflated/distinct StateFlow,
        // so this fires ONLY on the transition INTO playing — a suspension set mid-playback survives until
        // the next play or manual cursor set. Mirrors iOS `togglePlayback` clearing the flag on its play
        // branch. Covers every play entry point uniformly (transport, FAB, media notification, PiP).
        viewModelScope.launch {
            state.collect { if (it == PlaybackState.PLAYING) applyFollowEvent(PlaybackFollowEvent.PlaybackStarted) }
        }
    }

    /** Route a [PlaybackFollowEvent] through the pure [nextPlaybackFollowSuspended] transition so the
     * set/clear rules live in one plain-JVM-testable place. */
    private fun applyFollowEvent(event: PlaybackFollowEvent) {
        _isPlaybackFollowSuspended.value = nextPlaybackFollowSuspended(
            current = _isPlaybackFollowSuspended.value,
            isPlaying = state.value == PlaybackState.PLAYING,
            event = event,
        )
    }

    /**
     * The reader scrolled, pinch-zoomed, or turned the page by hand. While playback is active this
     * suspends cursor auto-follow (auto-scroll / auto-page-turn) until playback restarts or the cursor is
     * set manually — so the reader can look ahead / back without the page snapping back to the playhead.
     * A no-op when not playing: there is nothing to follow while paused / stopped, and a stray gesture must
     * not leave a suspension that survives into the next play (which re-arms follow anyway). Mirrors iOS
     * `suspendPlaybackFollowForManualViewportChange`.
     */
    fun suspendPlaybackFollowForManualViewportChange() =
        applyFollowEvent(PlaybackFollowEvent.ManualViewportChangeBegan)

    /**
     * Clear the manual-viewport suspension so playback auto-follow resumes. Called on any manual cursor
     * set (tap-seek / measure-step / seek bar scrub / rehearsal-mark / jump-to-start); playback (re)start
     * clears it via the `state` observer above. Mirrors iOS `resumePlaybackFollow`.
     */
    fun resumePlaybackFollow() = applyFollowEvent(PlaybackFollowEvent.ManualCursorSet)

    /**
     * Whether the Reader currently holds a score this engine can play. False before the first prepare
     * and again whenever the Reader moves to an item that has no playable score — a PDF.
     *
     * The engine is a bound service that outlives any one score, and nothing "unprepares" it, so its
     * own readouts go on describing the last score prepared. That is correct for the engine and wrong
     * for the UI: a PDF opened after a score would otherwise show that score's duration under a
     * transport it cannot use. Gating here rather than tearing the engine down keeps the fix in the
     * layer that knows what is on screen.
     */
    private val _hasPlayableScore = MutableStateFlow(false)

    val currentTimeSeconds: StateFlow<Double> = combine(
        _hasPlayableScore,
        _engine.flatMapLatest { it?.currentTimeSeconds ?: emptyFlow() },
    ) { hasPlayableScore, seconds -> if (hasPlayableScore) seconds else 0.0 }
        .stateIn(viewModelScope, SharingStarted.Eagerly, 0.0)

    val totalTimeSeconds: StateFlow<Double> = combine(
        _hasPlayableScore,
        _engine.flatMapLatest { it?.totalTimeSeconds ?: emptyFlow() },
    ) { hasPlayableScore, seconds -> if (hasPlayableScore) seconds else 0.0 }
        .stateIn(viewModelScope, SharingStarted.Eagerly, 0.0)

    val mixerChannels: StateFlow<List<MixerChannel>> = _engine
        .flatMapLatest { it?.mixerChannels ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    val currentRate: StateFlow<Float> = _engine
        .flatMapLatest { it?.currentRate ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, 1.0f)

    val loopRange: StateFlow<LoopRange?> = _engine
        .flatMapLatest { it?.loopRange ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    // The laid-out score handle, stored at [preparePlayback] time. It is the same Long the Reader
    // already feeds nativeNearestCursor / e.prepare, and the source the rehearsal-mark and
    // measure-step JNI calls below need. Null until a score has been prepared.
    @Volatile
    private var scoreHandle: Long? = null

    // The handle the ENGINE was actually prepared with — deliberately NOT the same field as [scoreHandle], which
    // [preparePlayback] refreshes unconditionally while the prepare itself is skipped whenever the transport is not
    // STOPPED. The two diverge exactly there, and the difference is what [isPreparedWith] answers.
    //
    // It exists because `ReaderViewModel` cannot free a score handle a resync superseded until it knows nothing is
    // still reading it, and this class is the one holder it cannot see: `prepare` decodes the score into the
    // player, and `notePreparedScore` hands the same handle to the bound `MediaSessionService` so it can hot-swap
    // the engine when a soundfont download lands. Both keep the pointer for as long as this stays set.
    @Volatile
    private var preparedScoreHandle: Long? = null

    // Handles claimed by a [preparePlayback] coroutine that has not finished. A prepare captures its handle by
    // value and then SUSPENDS on `engine.filterNotNull().first()` — the engine only exists once the playback
    // service binds — before dereferencing it, so between the launch and the prepare there is a window in which
    // [preparedScoreHandle] does not yet name the handle but the coroutine is about to use it.
    //
    // A single slot would not do: a second `preparePlayback` for a newer handle would overwrite the claim while
    // the first coroutine was still suspended on the old one, which is exactly the case this guards. A list is
    // also how duplicates stay correct — two prepares for the same handle each add and each remove one entry.
    // Cancelling the previous job instead was the other option and is NOT sufficient: cancellation is cooperative,
    // so a coroutine already past its suspend runs on to `ScoreMetadata.fetch` / `prepare` regardless.
    //
    // Entries are added and removed on Main (`viewModelScope` dispatches `Main.immediate`) and read from the
    // retirement drain on `Dispatchers.Default`, hence the explicit monitor rather than `@Volatile`.
    private val pendingPrepareHandles = mutableListOf<Long>()
    private val prepareLock = Any()

    /**
     * Whether the audio engine, the bound service it shares the handle with, or a prepare still in flight is
     * holding [handle].
     *
     * `ReaderViewModel.installPreparedHandleProbe` wires this in from the Reader screen, which is the only layer
     * that sees both view models. A `true` answer means a superseded handle must NOT be released yet — see
     * `ReaderViewModel.retiredHandlesToRelease` for the decision this feeds.
     */
    fun isPreparedWith(handle: Long): Boolean = synchronized(prepareLock) {
        isScoreHandleHeld(handle, preparedScoreHandle, pendingPrepareHandles)
    }

    // Rehearsal marks for the prepared score, loaded once the handle is known (see
    // [loadRehearsalMarks]). The transport bar renders one pill per entry, positioned by its
    // notated-time fraction; tapping a pill seeks the engine to that entry's cursor.
    private val _rehearsalMarks = MutableStateFlow<List<RehearsalMarkEntry>>(emptyList())
    val rehearsalMarks: StateFlow<List<RehearsalMarkEntry>> = _rehearsalMarks.asStateFlow()

    // ── Repeat / AB-loop ─────────────────────────────────────────────
    // The repeat controller mirrors iOS RepeatModel. It is installed once per score by the screen,
    // which supplies the persistence callbacks the app module owns (global mode → DataStore,
    // per-score A–B range → Room). Mode + range are surfaced as flows for the inspector/transport UI.
    private val _repeatController = MutableStateFlow<ReaderRepeatController?>(null)

    val repeatMode: StateFlow<RepeatMode> = _repeatController
        .flatMapLatest { it?.mode ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, RepeatMode.OFF)

    val abRange: StateFlow<AbRepeatRange?> = _repeatController
        .flatMapLatest { it?.abRange ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    /** Staged A endpoint measure index (or null). Drives the A button state + the A boundary marker. */
    val repeatPendingA: StateFlow<Int?> = _repeatController
        .flatMapLatest { it?.pendingA ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    /** Staged B endpoint measure index (or null). Drives the B button state + the B boundary marker. */
    val repeatPendingB: StateFlow<Int?> = _repeatController
        .flatMapLatest { it?.pendingB ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    /**
     * Installs the repeat controller once the host has wired per-score persistence. [persistMode]
     * writes the global DataStore pref; [loadRange]/[persistRange] read/write the per-score Room row.
     * Re-applies the active loop immediately (e.g. restoring an A–B range when reopening a score).
     */
    fun installRepeatController(
        initialMode: RepeatMode,
        loadRange: () -> AbRepeatRange?,
        persistRange: (AbRepeatRange?) -> Unit,
        persistMode: (RepeatMode) -> Unit,
    ) {
        _repeatController.value = ReaderRepeatController(
            // Fall back to measure 0 when no playback cursor exists yet (freshly prepared / stopped —
            // the playhead is logically at the start), so A/B can be marked before playback starts.
            currentMeasureProvider = { currentCursor.value?.measureIndexOrNull() ?: 0 },
            persistedRangeLoader = loadRange,
            persistRange = persistRange,
            persistMode = persistMode,
            applyLoop = ::applyLoop,
            initialMode = initialMode,
        )
    }

    fun setRepeatMode(mode: RepeatMode) { _repeatController.value?.setMode(mode) }
    fun setRepeatA() { _repeatController.value?.setA() }
    fun setRepeatB() { _repeatController.value?.setB() }

    /** Translates the controller's active loop into engine calls. */
    private fun applyLoop(range: AbRepeatRange?, mode: RepeatMode) {
        val e = engine.value ?: return
        when (mode) {
            RepeatMode.OFF -> e.clearLoop()
            RepeatMode.LOOP_ALL -> e.setLoopFullScore()
            RepeatMode.AB_LOOP ->
                if (range != null) e.setLoopMeasures(range.startMeasure, range.endMeasure)
                else e.clearLoop()
        }
    }

    // ── UI-facing controls without an engine-side observable ─────────
    // The engine exposes setMasterVolume / setMetronomeEnabled but no StateFlow for
    // either, so the inspector's UI state lives here (session-only, matching the Reader
    // MVP — no persistence). Defaults mirror the engine's post-prepare defaults.
    private val _masterVolume = MutableStateFlow(1.0f)
    val masterVolume: StateFlow<Float> = _masterVolume.asStateFlow()

    private val _metronomeEnabled = MutableStateFlow(false)
    val metronomeEnabled: StateFlow<Boolean> = _metronomeEnabled.asStateFlow()

    // A4 reference pitch (Hz). Session-only per the Reader MVP convention — no persistence here.
    // Seeded from the global SettingsPrefs default at prepare time (see [preparePlayback]).
    // The live value is the source of truth for the inspector slider; the engine is kept
    // in sync via [setA4ReferenceHz].
    private val _a4ReferenceHz = MutableStateFlow(440.0)
    val a4ReferenceHz: StateFlow<Double> = _a4ReferenceHz.asStateFlow()

    // The global default A4 from SettingsPrefs, stored when the score is seeded so the
    // inspector can display the per-score value's cents offset relative to the user's default.
    private val _globalA4ReferenceHz = MutableStateFlow(440.0)
    val globalA4ReferenceHz: StateFlow<Double> = _globalA4ReferenceHz.asStateFlow()

    // Transpose / count-in are pushed down from the Reader (per-score and global respectively) and held
    // here so [preparePlayback] can re-apply them: a prepare builds a fresh synth at concert pitch with
    // the setting cleared, so without this a score opened while transposed would sound at pitch and a
    // count-in would silently stop happening after a soundfont swap.
    private var transposeSemitones: Int = 0
    private var countInEnabled: Boolean = false

    /** Sets master output volume (0..1) and reflects it for the inspector UI. */
    fun setMasterVolume(volume: Float) {
        _masterVolume.value = volume
        engine.value?.setMasterVolume(volume)
    }

    /** Enables/disables the metronome and reflects it for the inspector UI. */
    fun setMetronomeEnabled(enabled: Boolean) {
        _metronomeEnabled.value = enabled
        engine.value?.setMetronomeEnabled(enabled)
    }

    /**
     * Audible half of transpose: retunes the melodic channels by [semitones]. The notation half is the
     * re-spelled layout the Reader requests through its display options — both are driven from the same
     * per-score value, so they cannot drift apart.
     *
     * Held so it can be re-applied after a prepare (a fresh synth starts at concert pitch).
     */
    fun setTranspose(semitones: Int) {
        transposeSemitones = semitones
        engine.value?.setTranspose(semitones)
    }

    /** Global count-in setting, consumed by the engine at the next `play()`. */
    fun setCountInEnabled(enabled: Boolean) {
        countInEnabled = enabled
        engine.value?.countInEnabled = enabled
    }

    /**
     * Seeds the A4 reference pitch from the global SettingsPrefs default. Called once per
     * score load (before [preparePlayback]) so the inspector can display the current per-score
     * value's cents offset relative to the user's global preference.
     */
    fun seedGlobalA4ReferenceHz(hz: Double) {
        _globalA4ReferenceHz.value = hz
        setA4ReferenceHz(hz)
    }

    // Hook run once each time a player finishes preparing (inside [preparePlayback], after the seeds +
    // loop are reapplied). The Reader screen installs this to replay persisted per-staff mixer overrides
    // onto the engine — it needs to run after prepare because the engine's mixer channels only exist
    // once a score is prepared, and a fresh player resets program / volume to score defaults.
    private var onPrepared: (() -> Unit)? = null

    fun installOnPrepared(callback: () -> Unit) {
        onPrepared = callback
    }

    // Tempo multiplier (engine rate) the score opened with. Held so [preparePlayback] can re-apply it
    // after prepare (a freshly prepared FluidSynth player resets to rate 1.0, same as it resets master
    // volume / metronome — see the soundfont-reload re-push). The inspector reads the live rate from
    // [currentRate]; this is only the seed-and-reapply source.
    private val _tempoSeed = MutableStateFlow(1.0f)

    /**
     * Seeds the per-score playback scalars when a score opens, restoring whatever the user last saved
     * for it (the app resolves any "inherit" sentinels first). Master volume / A4 reflect into the
     * inspector immediately via their MutableStateFlows; the engine is (re)synced from these seeds in
     * [preparePlayback] after the player is prepared, since prepare resets the synth's volume / rate /
     * tuning. Persistence is *not* re-triggered here — these values came from storage.
     */
    fun seedPlaybackScalars(masterVolume: Float, tempoMultiplier: Float, a4ReferenceHz: Double, globalA4ReferenceHz: Double) {
        _globalA4ReferenceHz.value = globalA4ReferenceHz
        _tempoSeed.value = tempoMultiplier
        setMasterVolume(masterVolume)
        setA4ReferenceHz(a4ReferenceHz)
    }

    /**
     * Sets the A4 reference pitch (Hz) and applies it to the engine as master-tuning cents
     * relative to standard A4 = 440 Hz. Also reflects the new value for the inspector slider.
     */
    fun setA4ReferenceHz(hz: Double) {
        _a4ReferenceHz.value = hz
        val cents = 1200.0 * log2(hz / 440.0)
        engine.value?.setMasterTuning(cents)
    }

    /**
     * Apply a tapped-cursor selection: seek the engine to it always, and — only while playback is
     * stopped/paused AND the tapped element is a note — audition that single note for 500 ms.
     *
     * Mirrors iOS `ReaderPlaybackSession.setManualCursor`: the seek moves the manual cursor
     * unconditionally; the one-shot preview never overlays a continuous playback stream, and rests
     * (or any non-note item) seek silently. [cursor] is the full-score engine-addressed cursor
     * returned by `nativeNearestCursor`, so its NoteID resolves against the prepared score.
     */
    fun handleTap(cursor: ScoreCursor) {
        val e = engine.value ?: return
        // A tap-to-place-cursor is an explicit manual set → resume follow (clears any suspension from the
        // reader having scrolled away during playback) so the view re-centers this target and keeps up.
        resumePlaybackFollow()
        e.seek(to = cursor)
        if (state.value == PlaybackState.PLAYING) return
        val item = (cursor as? ScoreCursor.Item)?.arg0 ?: return
        val noteId = (item as? ScoreItemID.Note)?.arg0 ?: return
        playNotePreview(noteId)
    }

    /**
     * Sounds one note for [PREVIEW_MILLIS], and nothing else — no seek, no cursor move.
     *
     * Shared by tap-to-seek above and the note editor's audition seam (`NoteAuditioning`, wired in from the
     * composition root), which is the whole reason it is its own method: the editor's preview has to be the same
     * sound and the same length as the reader's, and iOS gets that by both sides calling one `playPreview`.
     *
     * [noteId] resolves against the score behind the engine's handle, so an editing caller must have carried its
     * edit into that score already — see `EditSessionRelay.sound`.
     */
    fun playNotePreview(noteId: NoteID) {
        engine.value?.playPreview(noteId, durationMillis = PREVIEW_MILLIS)
    }

    fun preparePlayback(scoreHandle: Long) {
        // Claim the handle FIRST — before anything in this function reads it, not merely before the coroutine can
        // suspend. `loadRehearsalMarks` below is already a dereference (`nativeRehearsalMarks`), and this function
        // does not suspend, so `LaunchedEffect(scoreHandle)`'s cooperative cancellation cannot stop a
        // `preparePlayback(A)` that has already entered: the `Dispatchers.Default` retirement drain can be freeing A
        // at that moment. Claiming here makes the claim's scope the whole function, which is what its own doc
        // promises. It also covers the long window the coroutine needs it for: that captures `scoreHandle` by value,
        // waits on `engine.filterNotNull().first()` — potentially a long wait, since the engine only appears once
        // the playback service binds — and only then dereferences it (`ScoreMetadata.fetch`, `e.prepare`). See
        // [pendingPrepareHandles].
        synchronized(prepareLock) { pendingPrepareHandles += scoreHandle }
        // Everything from here to the `launch` is inside the claim's scope but OUTSIDE the coroutine's own
        // `finally`, so a throw here — `loadRehearsalMarks` decodes a JNI payload — would strand the claim for the
        // life of this view model and make the retirement drain refuse that handle forever. Releasing on the way out
        // costs one `catch`; the claim is NOT released on the success path, because from the `launch` onward the
        // coroutine's `finally` owns it.
        try {
            // Stash the handle for the rehearsal-mark / measure-step JNI calls, and load the marks now
            // that we know it. Both happen synchronously off the same handle the Reader supplies.
            this.scoreHandle = scoreHandle
            loadRehearsalMarks(scoreHandle)
            _hasPlayableScore.value = true
        } catch (t: Throwable) {
            synchronized(prepareLock) { pendingPrepareHandles.remove(scoreHandle) }
            throw t
        }
        viewModelScope.launch {
            try {
                prepareLoadedScore(scoreHandle)
            } finally {
                // Every exit of the BLOCK releases the claim: the early return inside, a thrown prepare, and
                // cancellation while it is suspended. The one case this does not cover is `viewModelScope` being
                // already cancelled when `launch` runs — the block never starts, so this never runs, and the claim
                // is stranded. Deliberately not handled: that is reachable only after `onCleared`, by which point
                // the drain is gone too, and a stranded claim can only make a drain refuse a release, never free
                // early. Adding machinery for it would buy nothing over the leak it already degrades to.
                synchronized(prepareLock) { pendingPrepareHandles.remove(scoreHandle) }
            }
        }
    }

    /**
     * The body of [preparePlayback]'s coroutine, split out only so its caller can wrap it in the one `finally` that
     * releases the [pendingPrepareHandles] claim on every exit — including `return@launch`, which would otherwise
     * need repeating at each early return.
     *
     * [scoreHandle] is safe to dereference throughout precisely because that claim is held: `ReaderViewModel`'s
     * retirement drain asks [isPreparedWith] before freeing a superseded handle, and a claimed one is refused.
     */
    private suspend fun prepareLoadedScore(scoreHandle: Long) {
        val e = engine.filterNotNull().first()
        ScoreMetadata.fetch(scoreHandle)?.let { meta ->
            serviceBinder?.updateMetadata(title = meta.title, composer = meta.composer)
        }
        if (e.state.value != PlaybackState.STOPPED) return
        // Apply the current A4 reference pitch before prepare so the engine's
        // internal masterTuningCents is set even if the engine wasn't connected when
        // setA4ReferenceHz was first called (engine was null at that point).
        val cents = 1200.0 * log2(_a4ReferenceHz.value / 440.0)
        e.setMasterTuning(cents)
        try {
            e.prepare(scoreHandle)
            hasLoadedIntoPlayback = true
            preparedScoreFingerprint = SheetMusicJNI.nativeScoreFingerprint(scoreHandle)
            // The two holders this class publishes move as ONE step, service first (SP4 whole-branch review), and
            // immediately after the `prepare` that made them true.
            //
            // `notePreparedScore` hands the bound `MediaSessionService` the handle it re-prepares from when a
            // soundfont download lands (`reloadSoundfont`). `preparedScoreHandle` is what `isPreparedWith` — and
            // through it `ReaderViewModel`'s retirement drain — reads to decide whether a superseded handle may be
            // freed, so moving it to the FRESH handle is also what declares the PREVIOUS one free. While that
            // assignment ran several statements ahead of `notePreparedScore`, a drain landing in that window freed
            // a pointer the service was still about to be handed and would later re-dereference. In this order
            // there is no moment when a live holder is reported as free.
            //
            // Both are on the path where `prepare` actually ran: the early return above leaves the engine on its
            // previous score, and claiming otherwise here would let `ReaderViewModel` free a handle the player is
            // still decoding from. Both are also ahead of the scalar re-application below, so a throw in any of
            // that cannot leave the engine holding a score neither holder names.
            serviceBinder?.notePreparedScore(scoreHandle)
            preparedScoreHandle = scoreHandle
            // Re-apply the seeded per-score playback scalars: a freshly prepared player resets the
            // synth's master volume and tempo (and metronome — re-pushed by the caller via the
            // soundfont-reload hook). Master tuning was already applied above; rate + volume are
            // restored here so a reopened score starts at the user's saved values.
            e.setMasterVolume(_masterVolume.value)
            e.setRate(_tempoSeed.value)
            // Transpose is a tuning shift on the same melodic channels the A4 calibration above
            // uses, and prepare cleared it with the rest; count-in is a plain flag the fresh engine
            // starts with off. Re-push both so a reopened (or soundfont-swapped) score keeps them.
            e.setTranspose(transposeSemitones)
            e.countInEnabled = countInEnabled
            // Re-apply the active loop now that a player is prepared (engine loop calls are
            // no-ops before prepare). Restores a persisted A–B range or full-score loop.
            _repeatController.value?.reapply()
            // Replay persisted per-staff mixer overrides (program / volume). Runs after prepare so
            // the engine has its mixer channels and the fresh player's defaults are overwritten.
            onPrepared?.invoke()
        } catch (ex: Exception) {
            android.util.Log.e("ReaderAudioVM", "prepare failed: ${ex.message}", ex)
        }
    }

    /**
     * Decodes the prepared score's rehearsal marks from the shared JNI bridge and publishes them
     * for the transport bar. The math (where each mark sits on the notated timeline, which cursor it
     * seeks to) lives entirely on the Swift side — this only decodes the wire payload.
     */
    fun loadRehearsalMarks(scoreHandle: Long) {
        _rehearsalMarks.value = RehearsalMarkCodec.decode(SheetMusicJNI.nativeRehearsalMarks(scoreHandle))
    }

    /**
     * Forget the score-derived transport state, for a Reader item that has no playable score — a PDF.
     *
     * Everything the transport row shows is per-score, but only [preparePlayback] ever replaced it, and
     * a PDF never reaches that. So a PDF inherited whatever the previous score left behind: its
     * duration in the readout and its rehearsal marks in the pill row, under a transport correctly
     * greyed out. Worse in a playlist, where an auto-advance into a PDF made the leftovers look like
     * the PDF's own.
     *
     * Deliberately does not stop or unprepare the engine. Reaching a PDF by auto-advance means playback
     * already ended, and the engine is a bound service shared with the notification transport — the
     * stale readouts are a presentation problem, so the repair belongs in what is published, not in the
     * audio graph's lifetime.
     */
    /**
     * Re-prepare the engine against a score that was edited in place, so playback sounds what the page shows.
     *
     * An edit mutates the score behind the SAME handle, so nothing the audio side watches changes: the Reader's
     * handle-keyed prepare never fires again and the player keeps the sequence it decoded when the score opened.
     * Editing a note and pressing play gave you the note you replaced. iOS answers this in
     * `ReaderViewModel.adoptEditedScore`, whose doc names the identical failure ("the engine's sequencer still
     * holds the pre-edit score") and releases the engine before re-preparing; this is the Android shape of that.
     *
     * **The `stop()` is not optional, it is the whole reason a plain [preparePlayback] does not work here.** Once a
     * score is prepared the engine sits at `PREPARED`, and [preparePlayback] declines anything that is not
     * `STOPPED` — the same guard [onCleared] documents from the other side. Without stopping first, this call
     * would be a silent no-op, which is exactly what the bug already was.
     *
     * Clearing [hasLoadedIntoPlayback] before stopping matters for the same reason it does in [onCleared]: `stop()`
     * nils the cursor, and a nil cursor while a score is loaded is what the Reader reads as end-of-score. Left set,
     * re-preparing after an edit would fire the playlist auto-advance and jump to the next item.
     *
     * Declines while PLAYING rather than cutting the audio off mid-phrase. The caller re-evaluates on every
     * transport change, so an edit made during playback — undo/redo stay enabled then — is adopted as soon as the
     * transport leaves PLAYING. The playhead returns to the start, which is inherent to re-preparing and is what
     * iOS does too.
     */
    fun reprepareForEditedScore(scoreHandle: Long) {
        val e = engine.value ?: return
        if (e.state.value == PlaybackState.PLAYING) return
        // Compare the CONTENT, not the handle: an edit mutates the score behind an unchanged handle, so the handle
        // cannot tell these apart. The edit session also bumps its revision for ops that change nothing the player
        // can hear — opening a session is one — and re-preparing for those would send the playhead back to the
        // start every time the user entered edit mode.
        val fingerprint = SheetMusicJNI.nativeScoreFingerprint(scoreHandle)
        if (fingerprint == preparedScoreFingerprint) return
        hasLoadedIntoPlayback = false
        e.stop()
        preparePlayback(scoreHandle)
    }

    // Fingerprint of the score the engine was last prepared against. Written where the prepare actually succeeded,
    // never on the way in: `preparePlayback` can decline (non-STOPPED engine) or throw, and recording it early
    // would make [reprepareForEditedScore] believe a prepare happened that did not.
    private var preparedScoreFingerprint: Long? = null

    fun clearPlayableScore() {
        _hasPlayableScore.value = false
        _rehearsalMarks.value = emptyList()
        scoreHandle = null
    }

    /** Steps the playback cursor back one measure (shared `Score.cursorSteppingMeasure` semantics). */
    fun stepMeasureBackward() = stepMeasure(direction = 0)

    /** Steps the playback cursor forward one measure (shared `Score.cursorSteppingMeasure` semantics). */
    fun stepMeasureForward() = stepMeasure(direction = 1)

    /**
     * Steps the current engine cursor by one measure in [direction] (0 = backward, 1 = forward) via
     * the shared JNI bridge, then seeks the engine to the result. Falls back to the first downbeat
     * (`Beat(0, 0)`) when there is no live cursor yet. No-op until a score handle is stored.
     */
    private fun stepMeasure(direction: Int) {
        val handle = scoreHandle ?: return
        val e = engine.value ?: return
        // A measure step is an explicit manual cursor set → resume follow (iOS `seek(toMeasureStart:)`).
        resumePlaybackFollow()
        val from = e.currentCursor.value ?: ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)
        val fromBytes = ScoreCursorCodec.encode(from)
        val targetBytes = SheetMusicJNI.nativeStepMeasureCursor(handle, fromBytes, direction)
        val target = ScoreCursorCodec.decode(targetBytes)
        e.seek(to = target)
    }

    companion object {
        /** Quarter-note beats the lookahead scroll anchor leads the live cursor. Mirrors iOS `SCROLL_LOOKAHEAD_BEATS`. */
        const val SCROLL_LOOKAHEAD_BEATS = 2.0

        /** Quarter-note beats the lookahead page anchor leads the live cursor. Mirrors iOS `PAGE_LOOKAHEAD_BEATS`. */
        const val PAGE_LOOKAHEAD_BEATS = 1.0

        /**
         * How long a one-shot note preview sounds. Matches the 0.5 s iOS passes on both of its preview paths
         * (`ReaderPlaybackSession.setManualCursor` and `EditorViewModel.performPendingAudition`).
         */
        const val PREVIEW_MILLIS = 500L
    }

    override fun onCleared() {
        // The Reader owns the playback session. This view model is scoped to the Reader's back-stack
        // entry, so onCleared runs exactly when that entry is finally removed — an in-app close (system
        // back, or any pop of the reader route back to the Library). Stop the engine there so audio never
        // outlives the Reader: the bound playback service keeps the engine alive on its own (that powers
        // PiP / background playback), so without this the score keeps playing after the Reader is gone,
        // and — because the engine stays non-STOPPED — the next Reader's preparePlayback early-returns on
        // its `state != STOPPED` guard, leaving the new score unprepared. NOT called when the Reader is
        // merely covered by a pushed detail (Edit-Info), backgrounded (Home → PiP / background playback),
        // or recreated on a configuration change, so those keep playing as intended. Clear the loaded
        // flag first so the stop()-induced cursor nil does not fire the end-of-score auto-advance.
        hasLoadedIntoPlayback = false
        engine.value?.stop()
        getApplication<Application>().unbindService(connection)
        super.onCleared()
    }
}

/**
 * Current measure index of a playback cursor, or null. Every audio cursor variant carries a measure
 * index except a staff-default clef anchor (which is not a playback position).
 */
/**
 * Whether anything on the audio side is still holding [handle] — the decision behind
 * [ReaderAudioViewModel.isPreparedWith], and therefore behind whether `ReaderViewModel` may free a score a resync
 * superseded.
 *
 * Two holders, and both have to count. [preparedHandle] is what `prepare` actually decoded into the player, which
 * the bound `MediaSessionService` also keeps for soundfont hot-swap — it can be re-dereferenced minutes later,
 * after the Reader is gone. [pendingHandles] are prepares that have launched but not finished: each captured its
 * handle by value and is suspended waiting for the engine to bind, so it will dereference a handle that
 * [preparedHandle] does not yet name.
 *
 * Pure and `internal` so it can be pinned off-device: [ReaderAudioViewModel] is an `AndroidViewModel` and this
 * module's JVM test source set has no `Application` to build one with (see `RecomputeSkipTest`'s own doc for the
 * same constraint). Freeing too early here is a use-after-free on the audio render thread; never freeing is the
 * leak the retirement drain exists to close, so both directions are worth a test.
 */
internal fun isScoreHandleHeld(handle: Long, preparedHandle: Long?, pendingHandles: List<Long>): Boolean =
    preparedHandle == handle || pendingHandles.contains(handle)

internal fun ScoreCursor.measureIndexOrNull(): Int? = when (this) {
    is ScoreCursor.Beat -> measureIndex
    is ScoreCursor.Item -> when (val id = arg0) {
        is ScoreItemID.Note -> id.arg0.measureIndex
        is ScoreItemID.Rest -> id.arg0.measureIndex
        is ScoreItemID.Tuplet -> id.arg0.measureIndex
        is ScoreItemID.Clef -> when (val anchor = id.arg0) {
            is ClefAnchor.Explicit -> anchor.arg0.measureIndex
            is ClefAnchor.StaffDefault -> null
        }
    }
}
