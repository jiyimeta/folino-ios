package com.keynumber.folino.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
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
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntSize
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.serialization.DecodedFrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage
import io.github.jiyimeta.sheetmusic.compose.render.FontProvider
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

@Composable
fun PagedScore(
    state: ReaderState.Ready,
    scoreHandle: Long?,
    fontProvider: FontProvider,
    audioVm: ReaderAudioViewModel,
    readerVm: ReaderViewModel,
    pageTapHintDismissed: Boolean,
    onDismissPageTapHint: () -> Unit,
) {
    // The original (vertical) program supplies the page WIDTH used for fit-width scaling.
    val basePage = state.program.pages.first()
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    var pagedPages by remember { mutableStateOf<List<EncodablePage>>(emptyList()) }
    // Document-Y page boundaries (mm): [0, top1, …, contentBottom] from nativePageBreaks.
    var breaksMm by remember { mutableStateOf(DoubleArray(0)) }
    var scale by remember { mutableFloatStateOf(1f) }
    var panOffset by remember { mutableStateOf(Offset.Zero) }

    val fitPxPerMM = if (basePage.widthMM > 0 && viewportSize.width > 0)
        (viewportSize.width / basePage.widthMM).toFloat() else 0f
    val viewportHeightMm: Double = if (fitPxPerMM > 0f) (viewportSize.height / fitPxPerMM).toDouble() else 0.0

    // Observe layout options so a display-setting change also triggers a re-fetch.
    val layoutOptions by readerVm.layoutOptions.collectAsStateWithLifecycle()

    // Build the per-page program + page breaks whenever the viewport height OR display options change
    // (incl. device rotation and any inspector edit that affects pagination).
    LaunchedEffect(scoreHandle, viewportHeightMm, layoutOptions) {
        if (scoreHandle != null && viewportHeightMm > 0.0) {
            val program = readerVm.pagedProgram(basePage.widthMM, viewportHeightMm)
            pagedPages = program?.pages ?: emptyList()
            breaksMm = readerVm.pageBreaks(viewportHeightMm)
        }
    }

    val pageCount = pagedPages.size
    val pagerState = rememberPagerState(pageCount = { pageCount })

    // Reset zoom + pan on page turn (iOS parity: each page enters at fit-width).
    LaunchedEffect(pagerState.currentPage) { scale = 1f; panOffset = Offset.Zero }

    // Auto page-turn: cursor's document-Y (mm) → its page band → animate there, unless dragging.
    LaunchedEffect(scoreHandle, breaksMm.size, breaksMm.firstOrNull(), breaksMm.lastOrNull()) {
        val h = scoreHandle ?: return@LaunchedEffect
        if (breaksMm.size < 2) return@LaunchedEffect
        audioVm.currentCursor.collectLatest { cursor ->
            if (cursor == null || pagerState.isScrollInProgress) return@collectLatest
            val bytes = SheetMusicJNI.nativeCursorFrame(h, ScoreCursorCodec.encode(cursor))
            if (bytes.isEmpty()) return@collectLatest
            val yMm = DecodedFrameCodec.decode(bytes).y.toDouble()
            var target = 0
            for (i in 0 until breaksMm.size - 1) {
                if (yMm >= breaksMm[i] && yMm < breaksMm[i + 1]) { target = i; break }
                if (i == breaksMm.size - 2) target = i
            }
            if (target != pagerState.currentPage) pagerState.animateScrollToPage(target)
        }
    }

    Box(
        Modifier.fillMaxSize().onSizeChanged { viewportSize = it },
        contentAlignment = Alignment.TopStart,
    ) {
        if (pageCount == 0) return@Box

        HorizontalPager(
            state = pagerState,
            userScrollEnabled = scale == 1f, // only swipe at unit zoom; while zoomed the gesture pans
            modifier = Modifier.fillMaxSize(),
        ) { pageIndex ->
            val pg = pagedPages[pageIndex]
            val contentWidthPx = pg.widthMM.toFloat() * fitPxPerMM * scale
            val contentHeightPx = pg.heightMM.toFloat() * fitPxPerMM * scale
            // Page top in absolute document px — used to shift the (absolute) cursor into page-local space.
            val pageTopPx = breaksMm[pageIndex].toFloat() * fitPxPerMM * scale

            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.White)
                    .clipToBounds()
                    // Pinch-zoom + pan gesture lives INSIDE the pager page (not as a sibling overlay),
                    // so HorizontalPager still receives single-finger horizontal swipes at scale == 1.
                    // At scale == 1 single-finger drags are NOT consumed here → they reach the pager.
                    .pointerInput(fitPxPerMM, pageIndex) {
                        if (fitPxPerMM <= 0f) return@pointerInput
                        awaitEachGesture {
                            awaitFirstDown(requireUnconsumed = false)
                            do {
                                val event = awaitPointerEvent()
                                val activeCount = event.changes.count { it.pressed }
                                val minPanX = -(size.width * (scale - 1f)).coerceAtLeast(0f)
                                val minPanY = -(size.height * (scale - 1f)).coerceAtLeast(0f)
                                if (activeCount >= 2) {
                                    val zoom = event.calculateZoom()
                                    if (zoom != 1f) {
                                        val c = event.calculateCentroid(useCurrent = true)
                                        if (!c.x.isNaN()) scale = (scale * zoom).coerceIn(1f, 8f)
                                    }
                                    val pan = event.calculatePan()
                                    if (pan != Offset.Zero && scale > 1f) {
                                        panOffset = Offset(
                                            (panOffset.x + pan.x).coerceIn(minPanX, 0f),
                                            (panOffset.y + pan.y).coerceIn(minPanY, 0f),
                                        )
                                    }
                                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                                } else if (activeCount == 1 && scale > 1f) {
                                    val pan = event.calculatePan()
                                    if (pan != Offset.Zero) {
                                        panOffset = Offset(
                                            (panOffset.x + pan.x).coerceIn(minPanX, 0f),
                                            (panOffset.y + pan.y).coerceIn(minPanY, 0f),
                                        )
                                        event.changes.forEach { if (it.positionChanged()) it.consume() }
                                    }
                                }
                            } while (event.changes.any { it.pressed })
                        }
                    },
                contentAlignment = Alignment.TopStart,
            ) {
                // Page content is already page-local (drawn from y=0); only user pan translates it.
                Box(
                    Modifier
                        .size(
                            width = with(density) { contentWidthPx.toDp() },
                            height = with(density) { contentHeightPx.toDp() },
                        )
                        .graphicsLayer { translationX = panOffset.x; translationY = panOffset.y },
                ) {
                    ScorePage(
                        page = pg,
                        fontProvider = fontProvider,
                        pxPerMM = fitPxPerMM * scale,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                // Cursor overlay works in ABSOLUTE document coords; shift up by this page's top so it
                // lands in page-local space. Off-page cursors fall outside the band and are clipped.
                scoreHandle?.let { h ->
                    PlaybackCursorOverlay(
                        scoreHandle = h,
                        cursorFlow = audioVm.currentCursor,
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        panOffset = Offset(panOffset.x, panOffset.y - pageTopPx),
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }
        }

        // The nav overlay scales + pans in lockstep with the page content so the buttons zoom with
        // the score (iOS parity). Transform origin is the top-left to match the content box.
        PageTapOverlay(
            viewportSize = viewportSize,
            currentPage = pagerState.currentPage,
            pageCount = pageCount,
            showsHint = !pageTapHintDismissed,
            onAnyZoneTouchDown = onDismissPageTapHint,
            onFirst = { scope.launch { pagerState.animateScrollToPage(0) } },
            onPrev = { scope.launch { pagerState.animateScrollToPage((pagerState.currentPage - 1).coerceAtLeast(0)) } },
            onNext = { scope.launch { pagerState.animateScrollToPage((pagerState.currentPage + 1).coerceAtMost(pageCount - 1)) } },
            onLast = { scope.launch { pagerState.animateScrollToPage(pageCount - 1) } },
            modifier = Modifier.graphicsLayer {
                scaleX = scale
                scaleY = scale
                translationX = panOffset.x
                translationY = panOffset.y
                transformOrigin = TransformOrigin(0f, 0f)
            },
        )
    }
}
