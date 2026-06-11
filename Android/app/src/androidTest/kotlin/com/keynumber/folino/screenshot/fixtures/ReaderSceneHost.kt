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
import com.keynumber.folino.reader.PartDescriptor
import com.keynumber.folino.reader.ReaderAudioViewModel
import com.keynumber.folino.reader.ReaderState
import com.keynumber.folino.reader.ReaderViewModel
import com.keynumber.folino.reader.fixedPxPerMm
import com.keynumber.folino.reader.layoutWidthMm
import com.keynumber.folino.reader.nearestCursorForTap
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

// Fixed score id used by the Reader screenshot scenes. The bundled Now_is_the_time.mscz is staged
// into filesDir/Scores/<this>.mscz, then ReaderViewModel.load reads it back exactly as production does.
private const val READER_SCORE_ID = "00000000-0000-0000-0000-0000000000b0"

// Shared staff size for every score-rendering screenshot scene. The production default
// (`LayoutOptions.DEFAULT.staffSize = 28.0`) renders the staves too large for a marketing frame, so
// the screenshot scenes lay out at this smaller size: the notes/staves still read clearly but show
// more of the music per frame. Used by ReaderCursor (10), DisplayHidden (20), LoopAll (30),
// AbRepeat (40), and Pip (60); Library (50) has no score.
internal const val SCREENSHOT_STAFF_SIZE = 18.0

// Title shown in the Reader top app bar for the score-rendering scenes — the bundled mock score's
// title (Now_is_the_time.mscz). Hard-coded so the scenes that host the real `ReaderTopBar` read the
// same label production would show for this score.
internal const val READER_SCENE_TITLE = "Now is the time"

// A loaded, laid-out Reader scene: the real ReaderViewModel driven to Ready over the bundled score.
// Holds whatever a screenshot scene needs to render the page (state + scoreHandle + the effective
// layoutOptions) AND to compose UI that depends on the score's structure (the decoded `parts`, used
// by the display-inspector scene to address staves and by callers that hide a subset of staves).
class ReaderSceneState internal constructor(
    val viewModel: ReaderViewModel,
    val state: ReaderState.Ready,
    val scoreHandle: Long,
    val parts: List<PartDescriptor>,
    val layoutOptions: LayoutOptions,
)

// Stages the bundled score once, builds a real ReaderViewModel, and drives it to Ready. Because some
// scenes need the score's `parts` to *decide* which staves to hide, the layout options are produced
// by a lambda that receives the decoded parts (null until they're known): the VM is first loaded with
// `optionsFor(null)`, and once parts publish, `optionsFor(parts)` is applied (the VM re-lays-out when
// layout options change). This is the shared load path; both the simple host and the inspector/PiP
// scenes go through it so the staging + readiness-gate logic lives in exactly one place.
//
// Returns null until the page is laid out and parts are known; callers render device chrome meanwhile.
@Composable
fun rememberReaderSceneState(optionsFor: (List<PartDescriptor>?) -> LayoutOptions): ReaderSceneState? {
    val context = LocalContext.current
    val appContext = context.applicationContext as Application

    // The load is async (parse + native layout on background dispatchers), so opt into the harness
    // readiness gate: the bitmap must wait until the page has actually rendered.
    remember { SceneReady.markGated() }

    val viewModel = remember {
        MockScores.stageReaderScore(appContext, READER_SCORE_ID)
        ReaderViewModel(appContext).also {
            it.setLayoutOptions(optionsFor(null))
            it.load(READER_SCORE_ID)
        }
    }

    val state by viewModel.state.collectAsStateCompat(ReaderState.Loading)
    val handle by viewModel.scoreHandle.collectAsStateCompat(null)
    val parts by viewModel.parts.collectAsStateCompat(emptyList())

    // Once the parts decode, re-apply the parts-aware options so the VM re-lays-out with (e.g.) the
    // hidden staves the scene wants. Re-runs only when the parts identity changes.
    LaunchedEffect(parts) {
        if (parts.isNotEmpty()) viewModel.setLayoutOptions(optionsFor(parts))
    }

    val ready = state as? ReaderState.Ready
    if (ready == null || handle == null || parts.isEmpty()) return null
    return ReaderSceneState(
        viewModel = viewModel,
        state = ready,
        scoreHandle = handle!!,
        parts = parts,
        layoutOptions = optionsFor(parts),
    )
}

// A live, PREPARED ReaderAudioViewModel for the screenshot scenes that show real engine-backed
// playback controls (the seek-bar-OFF PlaybackFab cluster and the PlaybackInspector's Mixer section).
//
// This drives the real production audio path: constructing the VM binds ReaderPlaybackService (which
// owns the AndroidPlaybackEngine) in its `init`; once the service connects, `engine` publishes; then
// `preparePlayback(scoreHandle)` calls `engine.prepare(...)`, which decodes the score into the per-staff
// `mixerChannels`. No audio plays — the playback state stays STOPPED — so this is safe for a static
// capture. The real components gate their `enabled` state on `engine != null` and derive the mixer rows
// from `mixerChannels`, so both must be live for the controls to render non-grayed with Parts rows.
//
// Returns null until the engine has bound AND the mixer is populated (the prepared signal). Callers
// render device chrome meanwhile; readiness for the capture is the caller's responsibility (gate the
// `SceneReady` signal on a non-null return here in addition to the page render).
@Composable
fun rememberPreparedAudioVm(scoreHandle: Long?): ReaderAudioViewModel? {
    val context = LocalContext.current
    val appContext = context.applicationContext as Application

    val audioVm = remember { ReaderAudioViewModel(appContext) }

    val mixerChannels by audioVm.mixerChannels.collectAsStateCompat(emptyList())

    // Wait for the service to bind (engine non-null), then prepare playback over the staged score.
    // Re-runs when the handle resolves. `preparePlayback` itself suspends on `engine.filterNotNull()`,
    // but we also `first()` the engine here so the prepare only fires once a handle exists.
    LaunchedEffect(scoreHandle) {
        val handle = scoreHandle ?: return@LaunchedEffect
        // Block until the bound service publishes the engine, then kick the real prepare flow.
        audioVm.engine.filter { it != null }.first()
        audioVm.preparePlayback(handle)
    }

    // Surface the VM only once the engine has populated the mixer — the "prepared" signal the real
    // controls need (engine bound + score decoded into per-staff channels).
    return if (mixerChannels.isNotEmpty()) audioVm else null
}

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
    val scene = rememberReaderSceneState { layoutOptions }
    if (scene == null) {
        // While loading, render nothing — the frame still shows the device chrome + opaque fill.
        Box(Modifier.fillMaxSize())
        return
    }
    ReaderSceneContent(
        state = scene.state,
        scoreHandle = scene.scoreHandle,
        layoutOptions = scene.layoutOptions,
        withCursor = withCursor,
        onLayoutWidthMm = scene.viewModel::setLayoutWidthMm,
    )
}

// Static adaptation of ReaderScreen.ReadyScore: fit-width page pinned to top, no scroll/gesture/pinch.
@Composable
fun ReaderSceneContent(
    state: ReaderState.Ready,
    scoreHandle: Long,
    layoutOptions: LayoutOptions,
    withCursor: Boolean,
    onLayoutWidthMm: (Double) -> Unit = {},
    // When false, the page still renders but does NOT release the capture gate — the scene owns the
    // SceneReady signal (e.g. it must also wait on a prepared audio engine before capturing).
    signalReadyWhenRendered: Boolean = true,
) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val fontProvider = remember(context) { bundledFontProvider(context) }

    val page = state.program.pages.first()

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }

    // Fixed-density render (same pxPerMM on phone and tablet) + report the viewport-derived layout width
    // to the VM so the score reflows to the device width exactly like production. (Task 7 / iOS parity.)
    val fitPxPerMM = if (viewportSize.width > 0) fixedPxPerMm(density.density) else 0f
    LaunchedEffect(viewportSize.width, density.density) {
        if (viewportSize.width > 0) onLayoutWidthMm(layoutWidthMm(viewportSize.width, density.density))
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
        // couple of frames, then release the capture gate (unless the scene defers it to also wait
        // on a prepared audio engine).
        kotlinx.coroutines.delay(300)
        if (signalReadyWhenRendered) SceneReady.signalReady()
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
internal fun <T> StateFlow<T>.collectAsStateCompat(initial: T): androidx.compose.runtime.State<T> {
    val flow = this
    val result = remember { mutableStateOf(initial) }
    LaunchedEffect(flow) {
        flow.collect { result.value = it }
    }
    return result
}
