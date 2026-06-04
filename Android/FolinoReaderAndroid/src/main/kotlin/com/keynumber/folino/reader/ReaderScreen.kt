package com.keynumber.folino.reader

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.keynumber.folino.reader.swiftjava.FolinoReaderJNI
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.serialization.DecodedFrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.floor

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderScreen(
    scoreId: String,
    title: String,
    layoutMode: ReaderLayoutMode = ReaderLayoutMode.VERTICAL,
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

    var showInspector by remember { mutableStateOf(false) }
    // Open at full height so the dense inspector shows as many rows as possible at once.
    val inspectorSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

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
        bottomBar = { TransportBar(audioVm, onOpenInspector = { showInspector = true }) },
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
                is ReaderState.Ready -> when (layoutMode) {
                    ReaderLayoutMode.VERTICAL -> ReadyScore(s, scoreHandle, fontProvider, audioVm)
                    // Page / Horizontal surfaces are not implemented yet; both fall back to the
                    // vertical-scroll surface for now. Follow-up work replaces these branches with
                    // dedicated PagedScore() / HorizontalScore() composables — this `when` is the
                    // single branch point so those surfaces slot in without re-touching the wiring.
                    ReaderLayoutMode.HORIZONTAL -> ReadyScore(s, scoreHandle, fontProvider, audioVm)
                    ReaderLayoutMode.PAGE -> ReadyScore(s, scoreHandle, fontProvider, audioVm)
                }
            }
        }
    }
    if (showInspector) {
        val openingQuarterBpm by readerVm.openingQuarterBpm.collectAsStateWithLifecycle()
        PlaybackInspectorSheet(
            audioVm = audioVm,
            openingQuarterBpm = openingQuarterBpm,
            sheetState = inspectorSheetState,
            onDismiss = { showInspector = false },
        )
    }
}

@Composable
private fun ReadyScore(
    state: ReaderState.Ready,
    scoreHandle: Long?,
    fontProvider: io.github.jiyimeta.sheetmusic.compose.render.FontProvider,
    audioVm: ReaderAudioViewModel,
) {
    val page = state.program.pages.first()

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    var scale by remember { mutableFloatStateOf(1f) }

    val vScroll = rememberScrollState()
    val hScroll = rememberScrollState()
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()

    // fit-width: at scale 1 the page width exactly fills the viewport, so the
    // horizontal extent is zero (no horizontal scroll) — matching iOS zoom 1.0.
    val fitPxPerMM = if (page.widthMM > 0 && viewportSize.width > 0) {
        (viewportSize.width / page.widthMM).toFloat()
    } else {
        0f
    }
    val contentWidthPx = (page.widthMM.toFloat() * fitPxPerMM * scale)
    val contentHeightPx = (page.heightMM.toFloat() * fitPxPerMM * scale)
    val isZoomed = contentWidthPx > viewportSize.width + 0.5f

    // Vertical breathing room so the first/last system isn't flush. Tunable.
    val vPadPx = with(density) { 16.dp.toPx() }
    val padPx = with(density) { 24.dp.toPx() }

    // Auto-scroll: keep the playback cursor in view via the shared Domain
    // keep-in-view math (JNI). Vertical always; horizontal only when zoomed.
    LaunchedEffect(scoreHandle, fitPxPerMM, scale) {
        val handle = scoreHandle ?: return@LaunchedEffect
        if (fitPxPerMM <= 0f) return@LaunchedEffect
        audioVm.currentCursor.collectLatest { cursor ->
            if (cursor == null) return@collectLatest
            val bytes = SheetMusicJNI.nativeCursorFrame(handle, ScoreCursorCodec.encode(cursor))
            if (bytes.isEmpty()) return@collectLatest
            val frame = DecodedFrameCodec.decode(bytes)

            val yMin = vPadPx + frame.y * fitPxPerMM * scale
            val yMax = vPadPx + (frame.y + frame.height) * fitPxPerMM * scale
            val newY = FolinoReaderJNI.nativeScrollOffsetKeepingInView(
                vScroll.value.toDouble(),
                yMin,
                yMax,
                viewportSize.height.toDouble(),
                padPx.toDouble(),
            ).toFloat()
            if (abs(newY - vScroll.value) >= 0.5f) {
                vScroll.animateScrollTo(newY.toInt().coerceAtLeast(0))
            }

            if (isZoomed) {
                val xMin = (frame.x * fitPxPerMM * scale)
                val xMax = ((frame.x + frame.width) * fitPxPerMM * scale)
                val newX = FolinoReaderJNI.nativeScrollOffsetKeepingInView(
                    hScroll.value.toDouble(),
                    xMin,
                    xMax,
                    viewportSize.width.toDouble(),
                    padPx.toDouble(),
                ).toFloat()
                if (abs(newX - hScroll.value) >= 0.5f) {
                    hScroll.animateScrollTo(newX.toInt().coerceAtLeast(0))
                }
            }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged { viewportSize = it }
            // Pinch zoom: only two-finger gestures are consumed here; single-finger
            // drags fall through to the scroll modifiers (native fling + overscroll).
            .pointerInput(fitPxPerMM) {
                if (fitPxPerMM <= 0f) return@pointerInput
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val pressed = event.changes.count { it.pressed }
                        if (pressed >= 2) {
                            val zoom = event.calculateZoom()
                            if (zoom != 1f) {
                                val centroid = event.calculateCentroid(useCurrent = true)
                                val newScale = (scale * zoom).coerceIn(1f, 8f)
                                val ratio = newScale / scale
                                if (ratio != 1f && !centroid.x.isNaN() && !centroid.y.isNaN()) {
                                    val newX = focalAdjustedOffset(hScroll.value.toFloat(), centroid.x, ratio)
                                    val newY = focalAdjustedOffset(vScroll.value.toFloat(), centroid.y, ratio, vPadPx)
                                    scale = newScale
                                    // scrollTo is a suspend fun; PointerInputScope is a restricted
                                    // coroutine scope that doesn't allow arbitrary launches. Use the
                                    // composable-level scope (from rememberCoroutineScope) instead.
                                    scope.launch { hScroll.scrollTo(newX.toInt().coerceAtLeast(0)) }
                                    scope.launch { vScroll.scrollTo(newY.toInt().coerceAtLeast(0)) }
                                }
                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                            }
                        }
                    } while (event.changes.any { it.pressed })
                }
            },
        contentAlignment = Alignment.TopStart,
    ) {
        // Scroll modifiers: vertical always; horizontal only when zoomed so that
        // at fit-width there is zero horizontal interaction (no horizontal stretch).
        val scrollModifier = if (isZoomed) {
            Modifier.verticalScroll(vScroll).horizontalScroll(hScroll)
        } else {
            Modifier.verticalScroll(vScroll)
        }

        Box(scrollModifier) {
            Box(
                Modifier.size(
                    width = with(density) { contentWidthPx.toDp() },
                    height = with(density) { (contentHeightPx + vPadPx * 2).toDp() },
                ),
            ) {
                ScorePage(
                    page = page,
                    fontProvider = fontProvider,
                    pxPerMM = fitPxPerMM * scale,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = with(density) { vPadPx.toDp() }),
                )
                scoreHandle?.let { handle ->
                    PlaybackCursorOverlay(
                        scoreHandle = handle,
                        cursorFlow = audioVm.currentCursor,
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        panOffset = Offset.Zero,
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(vertical = with(density) { vPadPx.toDp() }),
                    )
                }
            }
        }
    }
}

/**
 * New scroll offset (px) that keeps the content point under the pinch centroid
 * fixed across a zoom step of ratio `r = newScale / oldScale`. Only the page
 * content scales by `r`; a constant leading [pad] (the fixed vertical padding
 * above the page, which does NOT scale with zoom) is held out of the scaling.
 * In scroll space the content point under the centroid is at
 * `scroll + centroid`; the scaling page part is `scroll + centroid - pad`, so
 * after scaling by `r` the new offset is
 * `pad + r * (scroll - pad + centroid) - centroid`. With `pad = 0` this reduces
 * to the simple `r * (scroll + centroid) - centroid`. The scroll state clamps
 * the result to `[0, maxValue]`, so no clamp is needed here.
 */
private fun focalAdjustedOffset(
    currentScroll: Float,
    centroid: Float,
    ratio: Float,
    pad: Float = 0f,
): Float = pad + ratio * (currentScroll - pad + centroid) - centroid

@Composable
private fun TransportBar(audioVm: ReaderAudioViewModel, onOpenInspector: () -> Unit) {
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
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onOpenInspector, enabled = isPrepared) {
                Icon(Icons.Default.Tune, contentDescription = "Playback controls")
            }
        }
    }
}

private fun formatTime(seconds: Double): String {
    val s = seconds.coerceAtLeast(0.0)
    val minutes = floor(s / 60).toLong()
    val secs = floor(s % 60).toLong()
    return "%02d:%02d".format(minutes, secs)
}
