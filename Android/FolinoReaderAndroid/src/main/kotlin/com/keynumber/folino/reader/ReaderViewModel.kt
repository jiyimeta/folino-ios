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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// A4 page in millimetres (matches the example's single-page layout).
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

    private var handle: ScoreHandle? = null

    init {
        startRecomputeLoop()
    }

    /** Push a new display-settings snapshot in from the app layer; drives a recompute. */
    fun setLayoutOptions(options: LayoutOptions) {
        _layoutOptions.value = options
    }

    /**
     * Recompute the layout program whenever the score handle OR the display
     * options change. `mapLatest` cancels any in-flight compute when a newer
     * (handle, options) pair arrives, after a short debounce, so rapid edits
     * collapse to a single native call.
     *
     * The layout mode (VERTICAL/HORIZONTAL/PAGE) is carried in the options blob
     * as-is; the horizontal/page RENDER surfaces are owned by parallel sessions.
     * This VM only produces the mode-appropriate layout program.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    private fun startRecomputeLoop() {
        viewModelScope.launch {
            combine(_scoreHandle, _layoutOptions) { h, opts -> h to opts }
                .mapLatest { (h, opts) ->
                    if (h == null) return@mapLatest
                    delay(RECOMPUTE_DEBOUNCE_MS)
                    val programBytes = withContext(Dispatchers.Default) {
                        SheetMusicJNI.nativeComputeLayout(h, PAGE_WIDTH_MM, PAGE_HEIGHT_MM, opts.encode())
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
        if (_state.value !is ReaderState.Loading && handle != null) return
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

    /** Multi-page program for page mode, paginated by the viewport height (mm). */
    suspend fun pagedProgram(pageWidthMm: Double, pageHeightMm: Double): DrawProgram? {
        val h = handle?.raw ?: return null
        val bytes = withContext(Dispatchers.Default) {
            SheetMusicJNI.nativeComputeLayout(h, pageWidthMm, pageHeightMm, layoutOptions.value.encode())
        }
        if (bytes.isEmpty()) return null
        return try { DrawProgramReader.decode(bytes) } catch (e: Exception) { null }
    }

    /** Document-Y page-break offsets (mm) for the cached layout at the given page height. */
    suspend fun pageBreaks(pageHeightMm: Double): DoubleArray {
        val h = handle?.raw ?: return DoubleArray(0)
        val bytes = withContext(Dispatchers.Default) {
            SheetMusicJNI.nativePageBreaks(h, pageHeightMm, layoutOptions.value.encode())
        }
        return PageBreaksCodec.decode(bytes)
    }

    override fun onCleared() {
        // Do NOT close `handle`: the same raw Long is used by the playback
        // engine (which outlives this ViewModel via the bound service).
        // Mirrors the example ScoreViewModel.onCleared rationale.
        super.onCleared()
    }
}
