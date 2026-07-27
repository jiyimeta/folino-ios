package com.keynumber.folino.reader.pdf

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableFloatState
import androidx.compose.runtime.MutableState
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntSize
import com.keynumber.folino.reader.PageTapOverlay
import com.keynumber.folino.reader.ReaderAudioViewModel
import com.keynumber.folino.reader.ReaderState
import com.keynumber.folino.reader.ReaderViewModel
import com.keynumber.folino.reader.ink.AnnotationSurfaceState
import kotlinx.coroutines.launch
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Pure geometry for [PagedPdfScore]'s "one fitted, centered page" layout — plain `Int`/`Float`/`Double`
 * arithmetic, unit-testable off-device, split out for the same reason [PdfVerticalLayout] is split out of
 * [PdfVerticalScore]: the composable itself needs a real Compose environment, this doesn't.
 *
 * Unlike the vertical surface, a paged page is never wider (or taller) than the viewport at rest — it is
 * scaled to FIT inside the viewport on whichever axis is tighter, then centered on the other axis,
 * mirroring how a single-photo viewer fits one image at a time. Both the live pinch scale and the settled
 * raster scale multiply that same fit size, and the resulting content is always aligned to the viewport's
 * CENTER, never its top-left corner — see [PagedPdfScore]'s class doc for why the composable pairs this
 * with a center-anchored `graphicsLayer` rather than [PdfVerticalScore]'s top-anchored one.
 */
internal object PagedPdfLayout {

    /**
     * The pixel width the page would render at, at pinch scale 1, so it fits ENTIRELY inside a
     * [viewportWidthPx] x [viewportHeightPx] viewport — the smaller of "fit by width" and "fit by height",
     * preserving the page's own aspect ratio ([pageWidthPt] x [pageHeightPt], as `PdfRenderer` reports it).
     * `0` for a not-yet-measured viewport (`<= 0` on either axis) or a degenerate page size — callers gate
     * on that the same way [PdfVerticalLayout.renderWidthPx]'s callers gate on `viewportKnown`.
     */
    fun fitWidthPx(viewportWidthPx: Int, viewportHeightPx: Int, pageWidthPt: Double, pageHeightPt: Double): Int {
        if (viewportWidthPx <= 0 || viewportHeightPx <= 0 || pageWidthPt <= 0.0 || pageHeightPt <= 0.0) return 0
        val ratio = min(viewportWidthPx / pageWidthPt, viewportHeightPx / pageHeightPt)
        return (pageWidthPt * ratio).roundToInt().coerceAtLeast(1)
    }

    /** [fitWidthPx] scaled by the pinch/raster [scale] — the actual width a page is measured/requested at. */
    fun renderWidthPx(fitWidthPx: Int, scale: Float): Int = (fitWidthPx * scale).roundToInt().coerceAtLeast(1)

    /** On-screen height (px) for a page rendered [renderWidthPx] wide, following its own aspect ratio. */
    fun heightForWidthPx(renderWidthPx: Int, pageWidthPt: Double, pageHeightPt: Double): Int =
        (renderWidthPx * pageHeightPt / pageWidthPt).roundToInt().coerceAtLeast(1)

    /**
     * The maximum distance (px, symmetric in both directions) a CENTERED page of [contentSizePx] may be
     * panned within a [viewportSizePx]-wide/tall viewport before its far edge would pull inside the
     * viewport's own edge — `0` once the page fits entirely on that axis (nothing to pan). Callers clamp a
     * pan offset to `-bound..bound`, unlike [PdfVerticalScore]'s top-anchored `0..-excess` clamp, because
     * this surface's content is centered rather than pinned to `(0, 0)` — see [PagedPdfScore]'s class doc.
     */
    fun panBoundPx(contentSizePx: Float, viewportSizePx: Float): Float =
        ((contentSizePx - viewportSizePx) / 2f).coerceAtLeast(0f)

    /**
     * The new pan offset (one axis) that keeps the content point under a pinch gesture's [centroidPx] fixed
     * across a zoom step of [ratio] (`newScale / oldScale`), for CENTER-anchored content — the
     * center-anchored counterpart to [PdfVerticalScore]'s (top-anchored) `focalAdjustedOffset`. Derived the
     * same way: solve for the new offset that maps the same content-relative fraction back to [centroidPx]
     * after the content size scales by [ratio]. Because a centered page's on-screen span is
     * `viewportCenter + panOffset ± contentSize / 2`, the `contentSize` terms cancel out of that derivation
     * entirely, leaving a formula that — unlike the top-anchored version — needs neither the before- nor
     * the after-zoom content size as an input.
     */
    fun focalAdjustedPan(panBefore: Float, centroidPx: Float, viewportSizePx: Float, ratio: Float): Float =
        ratio * panBefore + (1f - ratio) * (centroidPx - viewportSizePx / 2f)
}

/**
 * The paged PDF reading surface: one page of [state] per [HorizontalPager] page, fitted to the viewport
 * and centered — never top-anchored, since a PDF page's aspect ratio can differ wildly from the device's,
 * where top-anchoring would strand it against one edge. Gestures, tap zones, and the one-time hint mirror
 * `PagedScore` (the score reader's page-mode sibling): swipe/tap-zone page turns, and pinch-to-zoom with
 * pan while zoomed. `PagedScore` disables `HorizontalPager`'s own swipe once `scale > 1f` (zoomed) so a
 * single-finger drag pans instead of turning the page — reproduced here unchanged; [PageTapOverlay]'s edge
 * zones keep working regardless of zoom, so a zoomed reader can still jump pages via the tap zones even
 * though swipe-to-turn is off.
 *
 * The zoom itself follows [PdfVerticalScore]'s two-stage design, not `PagedScore`'s single-stage one:
 * `PagedScore` re-lays-out its (vector) score content directly at the live pinch scale because redrawing
 * vector draw-commands at a new width is cheap, but a PDF page is a rasterized [Bitmap] — resizing the
 * actual render request on every pinch frame would mean re-rasterizing up to 60 times a second. So, exactly
 * as in [PdfVerticalScore]: the live pinch scale is where the fingers are RIGHT NOW, the raster scale is
 * the zoom [source] last rendered a bitmap at, and the two are bridged by a `remember`ed
 * `Modifier.graphicsLayer` whose `scaleX`/`scaleY` read the two backing states INSIDE the layer block —
 * never as a composable argument or a `Modifier.size` input. Only the raster scale feeds
 * [PagedPdfLayout.renderWidthPx] for the actual [PdfPageSource.bitmap] request width and the page's own
 * `Modifier.size`, and it only moves once, at gesture end (fingers-up) — never per frame.
 *
 * The one place this surface's shape actually differs from [PdfVerticalScore]'s is alignment: that surface
 * anchors every page's top-left at `(0, 0)` (it is a scrolling column, and `wrapContentSize(align =
 * TopStart, unbounded = true)` is what escapes its live-sized parent's clamp — see its class doc). This
 * surface instead centers its one page in the viewport, so the escape hatch is `wrapContentSize(align =
 * Center, unbounded = true)` and the `graphicsLayer`'s `transformOrigin` is the CENTER `(0.5f, 0.5f)`, not
 * `(0f, 0f)` — the same clamp hazard applies (the pager's page `Box` is `fillMaxSize`, so at `scale > 1` a
 * raster page wider than the viewport would otherwise be clamped down to the viewport's own bound by plain
 * `Modifier.size` constraint semantics), just escaped from the opposite corner.
 *
 * [PageTapOverlay] itself is deliberately NOT scaled/panned in lockstep with the zoomed content here, unlike
 * `PagedScore`'s own overlay. `PagedScore`'s content fills the full viewport width at rest, so scaling its
 * overlay from the same top-left origin keeps the tap zones glued to the score's own (possibly panned,
 * possibly overflowing) edges. This surface's content can be SMALLER than the viewport on either axis at
 * rest (a letterboxed page), so there is no such coherent relationship between "the viewport's raw edges,
 * scaled about its center" and "the page content's actual edges" — transforming the overlay the same way
 * would push the edge nav zones outside the visible viewport at high zoom instead of keeping them reachable.
 * Leaving the overlay untransformed keeps the tap zones exactly where a user expects them (the viewport's
 * physical edges) at every zoom level.
 *
 * There is no `scoreHandle` for a PDF yet (Task 12), so — like [PdfVerticalScore] — this surface has none of
 * `PagedScore`'s cursor overlay, tap-to-seek, or playback-auto-follow wiring. [audioVm], [readerVm], and
 * [autoFollowEnabled] are accepted for that future wiring; [annotation] is accepted for Task 11, per the
 * same convention [PdfVerticalScore]/`PagedScore` use for their own `annotation` parameter — none of the
 * four are read here.
 */
@Composable
internal fun PagedPdfScore(
    state: ReaderState.ReadyPdf,
    source: PdfPageSource,
    audioVm: ReaderAudioViewModel,
    readerVm: ReaderViewModel,
    pageTapHintDismissed: Boolean,
    onDismissPageTapHint: () -> Unit,
    /** Reserved for Task 12's playback auto-follow, once a PDF has a parsed score to follow. Unused here. */
    autoFollowEnabled: Boolean = true,
    /** User opt-out for the page-mode tap-zone overlay (`PagedScore` parity). Independent of
     * [pageTapHintDismissed], which only gates the one-time onboarding hint drawn on top of the zones. */
    pageTurnButtonsVisible: Boolean = true,
    /** Annotation layers + capture pipeline, owned by ReaderScreen. Wired in Task 11; unused here. */
    annotation: AnnotationSurfaceState? = null,
) {
    val scope = rememberCoroutineScope()

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    val scaleState = remember { mutableFloatStateOf(1f) }
    var scale by scaleState
    // The zoom the currently-displayed bitmap (and the page's own `Modifier.size`) is actually
    // rasterized/sized at, as opposed to `scale`, which is where the fingers are right now — see the class
    // doc. Reset to 1f alongside `scale` on every page turn (below), so each page enters at its own fit
    // size, unzoomed (`PagedScore` parity).
    val rasterScaleState = remember { mutableFloatStateOf(1f) }
    var rasterScale by rasterScaleState
    val panOffsetState = remember { mutableStateOf(Offset.Zero) }
    var panOffset by panOffsetState

    val pageCount = state.pageCount
    val pagerState = rememberPagerState(pageCount = { pageCount })

    // Reset zoom + pan on page turn (iOS / PagedScore parity: each page enters at fit size, unzoomed).
    LaunchedEffect(pagerState.currentPage) {
        scale = 1f
        rasterScale = 1f
        panOffset = Offset.Zero
    }

    // Drive the source's memory window off the settled page (Task 6's `setWindow` contract) — a pinch
    // alone never moves it, only an actual page turn does.
    LaunchedEffect(source, pagerState.currentPage, pageCount) {
        if (pageCount > 0) source.setWindow(pagerState.currentPage, radius = 1)
    }

    Box(Modifier.fillMaxSize().onSizeChanged { viewportSize = it }) {
        if (pageCount == 0) return@Box

        HorizontalPager(
            state = pagerState,
            // Only swipe at unit zoom; while zoomed the gesture pans instead (`PagedScore` parity).
            userScrollEnabled = scale == 1f,
            modifier = Modifier.fillMaxSize(),
        ) { pageIndex ->
            PagedPdfPage(
                index = pageIndex,
                pageWidthPt = state.pageWidthsPt[pageIndex],
                pageHeightPt = state.pageHeightsPt[pageIndex],
                viewportSize = viewportSize,
                source = source,
                scaleState = scaleState,
                rasterScaleState = rasterScaleState,
                panOffsetState = panOffsetState,
            )
        }

        // Gated on the opt-out toggle, exactly like `PagedScore`: swipe-to-turn (the pager itself, above)
        // keeps working even when the tap zones are hidden — only this overlay (and its onboarding hint)
        // disappears. See the class doc for why this overlay, unlike `PagedScore`'s, is not itself
        // scaled/panned in lockstep with the zoomed page content.
        if (pageTurnButtonsVisible) {
            PageTapOverlay(
                viewportSize = viewportSize,
                currentPage = pagerState.currentPage,
                pageCount = pageCount,
                showsHint = !pageTapHintDismissed,
                onAnyZoneTouchDown = onDismissPageTapHint,
                onFirst = { scope.launch { pagerState.animateScrollToPage(0) } },
                onPrev = {
                    scope.launch { pagerState.animateScrollToPage((pagerState.currentPage - 1).coerceAtLeast(0)) }
                },
                onNext = {
                    scope.launch {
                        pagerState.animateScrollToPage((pagerState.currentPage + 1).coerceAtMost(pageCount - 1))
                    }
                },
                onLast = { scope.launch { pagerState.animateScrollToPage(pageCount - 1) } },
            )
        }
    }
}

/**
 * One pager page: [source]'s bitmap for [index], fitted to [viewportSize] and centered — see
 * [PagedPdfScore]'s class doc for the two-stage zoom this participates in. A page whose bitmap isn't ready
 * yet (still rendering, or the viewport isn't measured) draws as a plain white rectangle — never a spinner,
 * never a layout jump, matching [PdfVerticalScore]'s `PdfPageItem`.
 */
@Composable
private fun PagedPdfPage(
    index: Int,
    pageWidthPt: Double,
    pageHeightPt: Double,
    viewportSize: IntSize,
    source: PdfPageSource,
    scaleState: MutableFloatState,
    rasterScaleState: MutableFloatState,
    panOffsetState: MutableState<Offset>,
) {
    val density = LocalDensity.current
    var scale by scaleState
    var panOffset by panOffsetState

    val viewportKnown = viewportSize.width > 0 && viewportSize.height > 0
    val fitWidthPx = if (viewportKnown) {
        PagedPdfLayout.fitWidthPx(viewportSize.width, viewportSize.height, pageWidthPt, pageHeightPt)
    } else {
        0
    }
    // Sizes the page's `Modifier.size` and the actual `PdfPageSource.bitmap` request — from the raster
    // scale only, never the live pinch scale — so a pinch frame neither re-rasterizes nor relays out this
    // page; see the class doc.
    val rasterWidthPx = if (fitWidthPx > 0) PagedPdfLayout.renderWidthPx(fitWidthPx, rasterScaleState.floatValue) else 0
    val rasterHeightPx = if (rasterWidthPx > 0) {
        PagedPdfLayout.heightForWidthPx(rasterWidthPx, pageWidthPt, pageHeightPt)
    } else {
        0
    }

    var bitmap by remember(index) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(index, rasterWidthPx) {
        if (rasterWidthPx <= 0) {
            bitmap = null
            return@LaunchedEffect
        }
        bitmap = source.bitmap(index, rasterWidthPx)
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.White)
            .clipToBounds()
            // Pinch-zoom + pan. Lives INSIDE the pager page (not a sibling overlay of the whole pager), so
            // at scale == 1 a single-finger drag is left unconsumed and reaches `HorizontalPager` itself —
            // `PagedScore`'s exact same trick, see its own comment.
            .pointerInput(index, fitWidthPx) {
                if (fitWidthPx <= 0) return@pointerInput
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    // Clamps a candidate pan (one gesture-local helper, closing over `size`/`fitWidthPx`/
                    // the page's own point size) to what `PagedPdfLayout.panBoundPx` allows AT `atScale` —
                    // shared by both the two-finger and one-finger branches below.
                    fun clamp(p: Offset, atScale: Float): Offset {
                        val liveWidthPx = PagedPdfLayout.renderWidthPx(fitWidthPx, atScale)
                        val liveHeightPx = PagedPdfLayout.heightForWidthPx(liveWidthPx, pageWidthPt, pageHeightPt)
                        val boundX = PagedPdfLayout.panBoundPx(liveWidthPx.toFloat(), size.width.toFloat())
                        val boundY = PagedPdfLayout.panBoundPx(liveHeightPx.toFloat(), size.height.toFloat())
                        return Offset(p.x.coerceIn(-boundX, boundX), p.y.coerceIn(-boundY, boundY))
                    }
                    do {
                        val event = awaitPointerEvent()
                        val activeCount = event.changes.count { it.pressed }
                        if (activeCount >= 2) {
                            val zoom = event.calculateZoom()
                            if (zoom != 1f) {
                                val centroid = event.calculateCentroid(useCurrent = true)
                                if (!centroid.x.isNaN() && !centroid.y.isNaN()) {
                                    val newScale = (scale * zoom).coerceIn(1f, 8f)
                                    val ratio = newScale / scale
                                    if (ratio != 1f) {
                                        val newX = PagedPdfLayout.focalAdjustedPan(
                                            panOffset.x, centroid.x, size.width.toFloat(), ratio,
                                        )
                                        val newY = PagedPdfLayout.focalAdjustedPan(
                                            panOffset.y, centroid.y, size.height.toFloat(), ratio,
                                        )
                                        panOffset = clamp(Offset(newX, newY), newScale)
                                        scale = newScale
                                    }
                                }
                            }
                            val pan = event.calculatePan()
                            if (pan != Offset.Zero && scale > 1f) {
                                panOffset = clamp(panOffset + pan, scale)
                            }
                            event.changes.forEach { if (it.positionChanged()) it.consume() }
                        } else if (activeCount == 1 && scale > 1f) {
                            val pan = event.calculatePan()
                            if (pan != Offset.Zero) {
                                panOffset = clamp(panOffset + pan, scale)
                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                            }
                        }
                    } while (event.changes.any { it.pressed })
                    // Fingers up: the one re-raster point for the whole gesture (`PdfVerticalScore` parity)
                    // — every pinch frame in between only moved the live scale, never the raster one.
                    if (rasterScaleState.floatValue != scaleState.floatValue) {
                        rasterScaleState.floatValue = scaleState.floatValue
                    }
                }
            },
    ) {
        // Escapes this Box's `fillMaxSize` bound so a raster page wider/taller than the viewport (any
        // `scale > 1`) isn't clamped back down to the viewport's own size by plain `Modifier.size`
        // constraint semantics — see the class doc. `align = Center` (not `PdfVerticalScore`'s `TopStart`)
        // matches this surface's centered content.
        Box(
            remember {
                Modifier
                    .wrapContentSize(align = Alignment.Center, unbounded = true)
                    .graphicsLayer {
                        val zoom = scaleState.floatValue / rasterScaleState.floatValue
                        scaleX = zoom
                        scaleY = zoom
                        translationX = panOffsetState.value.x
                        translationY = panOffsetState.value.y
                        transformOrigin = TransformOrigin(0.5f, 0.5f)
                    }
            },
        ) {
            if (rasterWidthPx > 0 && rasterHeightPx > 0) {
                Box(
                    Modifier.size(
                        width = with(density) { rasterWidthPx.toDp() },
                        height = with(density) { rasterHeightPx.toDp() },
                    ),
                ) {
                    bitmap?.let { bmp ->
                        val painterBitmap = remember(bmp) { bmp.asImageBitmap() }
                        Image(
                            bitmap = painterBitmap,
                            contentDescription = null,
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }
            }
        }
    }
}
