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
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.LoopRange
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
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
        }
        override fun onServiceDisconnected(name: ComponentName) {
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
            } catch (ex: Exception) {
                android.util.Log.e("ReaderAudioVM", "prepare failed: ${ex.message}", ex)
            }
        }
    }

    override fun onCleared() {
        getApplication<Application>().unbindService(connection)
        super.onCleared()
    }
}
