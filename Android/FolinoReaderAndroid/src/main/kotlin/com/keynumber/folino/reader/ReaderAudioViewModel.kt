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
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
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

    val currentTimeSeconds: StateFlow<Double> = _engine
        .flatMapLatest { it?.currentTimeSeconds ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, 0.0)

    val totalTimeSeconds: StateFlow<Double> = _engine
        .flatMapLatest { it?.totalTimeSeconds ?: emptyFlow() }
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
        e.seek(to = cursor)
        if (state.value == PlaybackState.PLAYING) return
        val item = (cursor as? ScoreCursor.Item)?.arg0 ?: return
        val noteId = (item as? ScoreItemID.Note)?.arg0 ?: return
        e.playPreview(noteId, durationMillis = 500L)
    }

    fun preparePlayback(scoreHandle: Long) {
        // Stash the handle for the rehearsal-mark / measure-step JNI calls, and load the marks now
        // that we know it. Both happen synchronously off the same handle the Reader supplies.
        this.scoreHandle = scoreHandle
        loadRehearsalMarks(scoreHandle)
        viewModelScope.launch {
            val e = engine.filterNotNull().first()
            ScoreMetadata.fetch(scoreHandle)?.let { meta ->
                serviceBinder?.updateMetadata(title = meta.title, composer = meta.composer)
            }
            if (e.state.value != PlaybackState.STOPPED) return@launch
            // Apply the current A4 reference pitch before prepare so the engine's
            // internal masterTuningCents is set even if the engine wasn't connected when
            // setA4ReferenceHz was first called (engine was null at that point).
            val cents = 1200.0 * log2(_a4ReferenceHz.value / 440.0)
            e.setMasterTuning(cents)
            try {
                e.prepare(scoreHandle)
                // Re-apply the seeded per-score playback scalars: a freshly prepared player resets the
                // synth's master volume and tempo (and metronome — re-pushed by the caller via the
                // soundfont-reload hook). Master tuning was already applied above; rate + volume are
                // restored here so a reopened score starts at the user's saved values.
                e.setMasterVolume(_masterVolume.value)
                e.setRate(_tempoSeed.value)
                // Re-apply the active loop now that a player is prepared (engine loop calls are
                // no-ops before prepare). Restores a persisted A–B range or full-score loop.
                _repeatController.value?.reapply()
                // Replay persisted per-staff mixer overrides (program / volume). Runs after prepare so
                // the engine has its mixer channels and the fresh player's defaults are overwritten.
                onPrepared?.invoke()
                // Record the handle so the service can re-prepare (hot-swap) the engine when a
                // high-quality soundfont download completes.
                serviceBinder?.notePreparedScore(scoreHandle)
            } catch (ex: Exception) {
                android.util.Log.e("ReaderAudioVM", "prepare failed: ${ex.message}", ex)
            }
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
        val from = e.currentCursor.value ?: ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)
        val fromBytes = ScoreCursorCodec.encode(from)
        val targetBytes = SheetMusicJNI.nativeStepMeasureCursor(handle, fromBytes, direction)
        val target = ScoreCursorCodec.decode(targetBytes)
        e.seek(to = target)
    }

    override fun onCleared() {
        getApplication<Application>().unbindService(connection)
        super.onCleared()
    }
}

/**
 * Current measure index of a playback cursor, or null. Every audio cursor variant carries a measure
 * index except a staff-default clef anchor (which is not a playback position).
 */
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
