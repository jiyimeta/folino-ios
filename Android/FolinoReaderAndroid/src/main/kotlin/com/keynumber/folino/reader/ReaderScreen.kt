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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.keynumber.folino.reader.swiftjava.FolinoReaderJNI
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.jiyimeta.sheetmusic.compose.cursor.CursorFrame
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.render.ScoreCanvas
import io.github.jiyimeta.sheetmusic.compose.render.ScoreTransform
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider
import kotlinx.coroutines.flow.collectLatest
import kotlin.math.abs
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
                is ReaderState.Ready -> ReadyScore(s, scoreHandle, fontProvider, audioVm)
            }
        }
    }
}

@Composable
private fun ReadyScore(
    state: ReaderState.Ready,
    scoreHandle: Long?,
    fontProvider: io.github.jiyimeta.sheetmusic.compose.render.FontProvider,
    audioVm: ReaderAudioViewModel,
) {
    var transform by remember { mutableStateOf(ScoreTransform()) }
    var pxPerMM by remember { mutableFloatStateOf(1f) }
    var viewportHeightPx by remember { mutableFloatStateOf(0f) }
    val padPx = with(LocalDensity.current) { 24.dp.toPx() }

    // Auto-scroll to keep the playback cursor in view — mirrors the iOS
    // VerticalScoreContainer behavior: scroll only when the cursor frame leaves
    // the viewport, by the minimal amount (with a small padding), preserving
    // manual pan while the cursor stays visible.
    LaunchedEffect(scoreHandle) {
        val handle = scoreHandle ?: return@LaunchedEffect
        audioVm.currentCursor.collectLatest { cursor ->
            if (cursor == null) return@collectLatest
            val frame = CursorFrame.decode(
                SheetMusicJNI.nativeCursorFrame(handle, ScoreCursorCodec.encode(cursor)),
            ) ?: return@collectLatest
            val newY = keepInViewOffsetY(
                panY = transform.panOffset.y,
                frameY = frame.y,
                frameH = frame.height,
                pxPerMM = pxPerMM,
                scale = transform.scale,
                viewportH = viewportHeightPx,
                contentHeightPx = (state.program.pages.first().heightMM * pxPerMM * transform.scale).toFloat(),
                pad = padPx,
            )
            if (abs(newY - transform.panOffset.y) >= 0.5f) {
                transform = transform.copy(panOffset = transform.panOffset.copy(y = newY))
            }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged { viewportHeightPx = it.height.toFloat() },
    ) {
        ScoreCanvas(
            page = state.program.pages.first(),
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

/**
 * Smallest pan-offset Y that keeps the cursor frame `[frameY, frameY+frameH]`
 * (document mm) inside the viewport with `pad` margin. Returns the current
 * `panY` unchanged when the cursor is already fully visible — preserving manual
 * scrolling while playback advances within the visible region. Mirrors iOS
 * `VerticalScoreContainer.adjustedScrollOffset`.
 *
 * Screen Y of a document point is `panY + docMm * pxPerMM * scale`; working in
 * scroll-offset space (`scroll = -panY`) makes the math match iOS directly.
 */
private fun keepInViewOffsetY(
    panY: Float,
    frameY: Double,
    frameH: Double,
    pxPerMM: Float,
    scale: Float,
    viewportH: Float,
    contentHeightPx: Float,
    pad: Float,
): Float {
    if (pxPerMM <= 0f || viewportH <= 0f) return panY
    val contentMin = (frameY * pxPerMM * scale).toFloat()
    val contentMax = ((frameY + frameH) * pxPerMM * scale).toFloat()
    val cur = -panY
    // Shared keep-in-view math (iOS + Android call the same Domain Swift via JNI).
    val rawCur = FolinoReaderJNI.nativeScrollOffsetKeepingInView(
        cur.toDouble(),
        contentMin.toDouble(),
        contentMax.toDouble(),
        viewportH.toDouble(),
        pad.toDouble(),
    ).toFloat()
    // Never scroll past the trailing content extent (top=0 .. content bottom).
    // iOS gets this clamp natively from UIScrollView; Android pans an unbounded
    // canvas, so clamp here (platform mechanics, not divergent logic).
    val maxScroll = maxOf(0f, contentHeightPx - viewportH)
    val newCur = rawCur.coerceIn(0f, maxScroll)
    return -newCur
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
