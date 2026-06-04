package com.keynumber.folino.reader

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.jiyimeta.sheetmusic.BravuraMetricsBuilder
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.compose.draw.DrawProgramReader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// A4 page in millimetres (matches the example's single-page layout).
private const val PAGE_WIDTH_MM = 210.0
private const val PAGE_HEIGHT_MM = 297.0

class ReaderViewModel(app: Application) : AndroidViewModel(app) {

    private val _state = MutableStateFlow<ReaderState>(ReaderState.Loading)
    val state: StateFlow<ReaderState> = _state.asStateFlow()

    private val _scoreHandle = MutableStateFlow<Long?>(null)
    val scoreHandle: StateFlow<Long?> = _scoreHandle.asStateFlow()

    // Opening quarter-note BPM (shared Swift `Score.openingQuarterBpm` via JNI), used by
    // the inspector's tempo readout: "♩ = round(bpm × rate)". Defaults to 120.
    private val _openingQuarterBpm = MutableStateFlow(120.0)
    val openingQuarterBpm: StateFlow<Double> = _openingQuarterBpm.asStateFlow()

    private var handle: ScoreHandle? = null

    /** Resolve the Library's on-disk score file: filesDir/Scores/<id>.mscz */
    private fun scoreFile(scoreId: String): File =
        File(File(getApplication<Application>().filesDir, "Scores"), "$scoreId.mscz")

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
            _scoreHandle.value = h.raw
            _openingQuarterBpm.value = withContext(Dispatchers.Default) {
                SheetMusicJNI.nativeOpeningQuarterBpm(h.raw)
            }

            val programBytes = withContext(Dispatchers.Default) {
                SheetMusicJNI.nativeComputeLayout(h.raw, PAGE_WIDTH_MM, PAGE_HEIGHT_MM)
            }
            if (programBytes.isEmpty()) {
                _state.value = ReaderState.Error("Layout produced no output")
                return@launch
            }

            val program = try {
                DrawProgramReader.decode(programBytes)
            } catch (e: Exception) {
                _state.value = ReaderState.Error("Could not render score: ${e.message}")
                return@launch
            }
            _state.value = ReaderState.Ready(program)
        }
    }

    override fun onCleared() {
        // Do NOT close `handle`: the same raw Long is used by the playback
        // engine (which outlives this ViewModel via the bound service).
        // Mirrors the example ScoreViewModel.onCleared rationale.
        super.onCleared()
    }
}
