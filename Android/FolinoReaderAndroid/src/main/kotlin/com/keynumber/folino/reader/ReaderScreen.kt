package com.keynumber.folino.reader

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.render.ScoreCanvas
import io.github.jiyimeta.sheetmusic.compose.render.ScoreTransform
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider
import kotlin.math.floor

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderScreen(
    scoreId: String,
    title: String,
    onBack: () -> Unit,
    readerVm: ReaderViewModel = viewModel(),
    audioVm: ReaderAudioViewModel = viewModel(),
) {
    val context = LocalContext.current
    val fontProvider = remember(context) { bundledFontProvider(context) }

    val state by readerVm.state.collectAsStateWithLifecycle()
    val scoreHandle by readerVm.scoreHandle.collectAsStateWithLifecycle()

    LaunchedEffect(scoreId) { readerVm.load(scoreId) }
    LaunchedEffect(scoreHandle) { scoreHandle?.let { audioVm.preparePlayback(it) } }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title.ifEmpty { "folino" }) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
        bottomBar = { TransportBar(audioVm) },
    ) { padding ->
        Box(
            Modifier
                .padding(padding)
                .fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            when (val s = state) {
                is ReaderState.Loading -> Text("Loading…")
                is ReaderState.Error -> Text(s.message, style = MaterialTheme.typography.bodyLarge)
                is ReaderState.Ready -> {
                    var transform by remember { mutableStateOf(ScoreTransform()) }
                    var pxPerMM by remember { mutableFloatStateOf(1f) }
                    Box(Modifier.fillMaxSize()) {
                        ScoreCanvas(
                            page = s.program.pages.first(),
                            fontProvider = fontProvider,
                            transform = transform,
                            onTransformChange = { transform = it },
                            onPxPerMMChange = { pxPerMM = it },
                            modifier = Modifier.fillMaxSize(),
                        )
                        scoreHandle?.let { handle ->
                            PlaybackCursorOverlay(
                                scoreHandle = handle,
                                cursorFlow = audioVm.currentCursor,
                                pxPerMM = pxPerMM,
                                scale = transform.scale,
                                panOffset = transform.panOffset,
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TransportBar(audioVm: ReaderAudioViewModel) {
    val playback by audioVm.state.collectAsStateWithLifecycle()
    val currentSecs by audioVm.currentTimeSeconds.collectAsStateWithLifecycle()
    val totalSecs by audioVm.totalTimeSeconds.collectAsStateWithLifecycle()
    val engine by audioVm.engine.collectAsStateWithLifecycle()

    val isPrepared = playback != PlaybackState.STOPPED && playback != PlaybackState.EXPORTING

    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconButton(
                onClick = {
                    if (playback == PlaybackState.PLAYING) engine?.pause() else engine?.play()
                },
                enabled = isPrepared,
            ) {
                if (playback == PlaybackState.PLAYING) {
                    Icon(Icons.Default.Pause, contentDescription = "Pause")
                } else {
                    Icon(Icons.Default.PlayArrow, contentDescription = "Play")
                }
            }
            Text(
                text = "${formatTime(currentSecs)} / ${formatTime(totalSecs)}",
                style = MaterialTheme.typography.bodySmall,
            )
            Slider(
                value = if (totalSecs > 0) (currentSecs / totalSecs).toFloat().coerceIn(0f, 1f) else 0f,
                onValueChange = { fraction ->
                    if (totalSecs > 0) engine?.seek(fraction * totalSecs)
                },
                enabled = isPrepared,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

private fun formatTime(seconds: Double): String {
    val s = seconds.coerceAtLeast(0.0)
    val minutes = floor(s / 60).toLong()
    val secs = floor(s % 60).toLong()
    return "%02d:%02d".format(minutes, secs)
}
