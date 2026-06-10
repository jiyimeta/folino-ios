package com.keynumber.folino.screenshot.fixtures

import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.ReaderState
import com.keynumber.folino.reader.ReaderViewModel
import com.keynumber.folino.reader.nearestCursorForTap
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

// Fixed score id used by the Reader screenshot scenes. The bundled Now_is_the_time.mscz is staged
// into filesDir/Scores/<this>.mscz, then ReaderViewModel.load reads it back exactly as production does.
private const val READER_SCORE_ID = "00000000-0000-0000-0000-0000000000b0"

// Stages the bundled score, drives a real ReaderViewModel to Ready, then renders the laid-out page
// (and optionally a static playback cursor) in a static, scroll-pinned-to-top adaptation of the
// production `ReadyScore`. No audio engine, no gesture handlers — just the score + an injected cursor.
//
// withCursor: when true, after the page is laid out we hit-test a tap near the middle of the first
//   measure (pure JNI, no engine) and feed the resulting ScoreCursor into the overlay.
@Composable
fun ReaderSceneHost(
    layoutOptions: LayoutOptions = LayoutOptions.DEFAULT,
    withCursor: Boolean = false,
) {
    val context = LocalContext.current
    val appContext = context.applicationContext as Application

    // This scene's score load is async (parse + native layout on background dispatchers), so opt into
    // the harness readiness gate: the bitmap must wait until the page has actually rendered.
    remember { SceneReady.markGated() }

    // Stage the asset + build the VM once. The VM's recompute loop drives `state` to Ready after the
    // handle publishes; we collect it below.
    val viewModel = remember {
        MockScores.stageReaderScore(appContext, READER_SCORE_ID)
        ReaderViewModel(appContext).also {
            it.setLayoutOptions(layoutOptions)
            it.load(READER_SCORE_ID)
        }
    }

    val state by viewModel.state.collectAsStateCompat(ReaderState.Loading)
    val handle by viewModel.scoreHandle.collectAsStateCompat(null)

    val ready = state as? ReaderState.Ready
    if (ready == null || handle == null) {
        // While loading, render nothing — the frame still shows the device chrome + opaque fill.
        Box(Modifier.fillMaxSize())
        return
    }

    ReaderSceneContent(
        state = ready,
        scoreHandle = handle!!,
        layoutOptions = layoutOptions,
        withCursor = withCursor,
    )
}

// Static adaptation of ReaderScreen.ReadyScore: fit-width page pinned to top, no scroll/gesture/pinch.
@Composable
private fun ReaderSceneContent(
    state: ReaderState.Ready,
    scoreHandle: Long,
    layoutOptions: LayoutOptions,
    withCursor: Boolean,
) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val fontProvider = remember(context) { bundledFontProvider(context) }

    val page = state.program.pages.first()

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }

    val fitPxPerMM = if (page.widthMM > 0 && viewportSize.width > 0) {
        (viewportSize.width / page.widthMM).toFloat()
    } else {
        0f
    }
    val vPadPx = with(density) { 16.dp.toPx() }

    // Injected static cursor. Recomputed once the page is laid out (fitPxPerMM + viewport known).
    val cursorFlow = remember { MutableStateFlow<ScoreCursor?>(null) }
    LaunchedEffect(scoreHandle, fitPxPerMM, viewportSize, withCursor) {
        if (fitPxPerMM <= 0f || viewportSize.width <= 0) return@LaunchedEffect
        if (withCursor) {
            // Tap near the middle of the first measure: x a short way in from the left margin, y at
            // the first staff. These are viewport-px; fold the fixed top padding into the content
            // offset so the helper's divide yields document-mm.
            val tapX = viewportSize.width * 0.12f
            val tapY = viewportSize.height * 0.10f
            val cursor = nearestCursorForTap(
                tap = Offset(tapX, tapY),
                contentOffsetPx = Offset(0f, vPadPx),
                pxPerMM = fitPxPerMM,
                scale = 1f,
                scoreHandle = scoreHandle,
                layoutOptionsBytes = layoutOptions.encode(),
            )
            if (cursor != null) cursorFlow.value = cursor
        }
        // Page is measured + (optionally) the cursor has been placed. Let the overlay/page draw a
        // couple of frames, then release the capture gate.
        kotlinx.coroutines.delay(300)
        SceneReady.signalReady()
    }

    Box(
        Modifier
            .fillMaxSize()
            // Mirror ReaderScreen's score region: a continuous white surface behind the (black-ink)
            // score, so the staves/notes are visible against the device frame's dark inner fill.
            .background(androidx.compose.ui.graphics.Color.White)
            .onSizeChanged { viewportSize = it },
        contentAlignment = Alignment.TopStart,
    ) {
        val contentWidthPx = page.widthMM.toFloat() * fitPxPerMM
        val contentHeightPx = page.heightMM.toFloat() * fitPxPerMM
        Box(
            Modifier.size(
                width = with(density) { contentWidthPx.toDp() },
                height = with(density) { (contentHeightPx + vPadPx * 2).toDp() },
            ),
        ) {
            ScorePage(
                page = page,
                fontProvider = fontProvider,
                pxPerMM = fitPxPerMM,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = with(density) { vPadPx.toDp() }),
            )
            PlaybackCursorOverlay(
                scoreHandle = scoreHandle,
                cursorFlow = cursorFlow,
                pxPerMM = fitPxPerMM,
                scale = 1f,
                panOffset = Offset.Zero,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(vertical = with(density) { vPadPx.toDp() }),
            )
        }
    }
}

// Local collectAsState replacement that doesn't require lifecycle (instrumented test composition has
// no LifecycleOwner-backed collector requirement); mirrors collectAsState semantics for a StateFlow.
@Composable
private fun <T> StateFlow<T>.collectAsStateCompat(initial: T): androidx.compose.runtime.State<T> {
    val flow = this
    val result = remember { mutableStateOf(initial) }
    LaunchedEffect(flow) {
        flow.collect { result.value = it }
    }
    return result
}
