package com.keynumber.folino.reader.pdf

import android.graphics.Bitmap
import android.graphics.Matrix
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
import androidx.compose.runtime.derivedStateOf
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
import com.keynumber.folino.reader.DrawingAnchorWire
import com.keynumber.folino.reader.DrawingAnchorWireCodec
import com.keynumber.folino.reader.PageFrameWire
import com.keynumber.folino.reader.PageFramesWire
import com.keynumber.folino.reader.PageFramesWireCodec
import com.keynumber.folino.reader.PageTapOverlay
import com.keynumber.folino.reader.ReaderAnnotationJNI
import com.keynumber.folino.reader.ReaderAudioViewModel
import com.keynumber.folino.reader.ReaderState
import com.keynumber.folino.reader.ReaderViewModel
import com.keynumber.folino.reader.ink.AnnotationLayers
import com.keynumber.folino.reader.ink.AnnotationSurfaceState
import com.keynumber.folino.reader.ink.PdfAnnotationCaptureController
import com.keynumber.folino.reader.ink.encodeWireArray
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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

    /**
     * A candidate pan offset ([panXPx], [panYPx]), clamped per axis to [panBoundPx] for a page rendered at
     * [atScale] (its [fitWidthPx] scaled by [atScale], following its own [pageWidthPt] x [pageHeightPt]
     * aspect ratio — the same [renderWidthPx]/[heightForWidthPx] pipeline the bitmap request itself uses)
     * inside a [viewportWidthPx] x [viewportHeightPx] viewport. This is the exact math [PagedPdfScore]'s
     * pinch/pan gesture applies on every frame to both the focal-zoom result and a plain one-/two-finger
     * drag — pulled out here, pure, specifically because it is where the CENTERED-content assumption is
     * baked in (via [panBoundPx]): a future regression back to top-left-anchored content would most likely
     * surface here first, and a test against this function catches that even though nothing here can
     * exercise the actual Compose layout tree.
     */
    fun clampPan(
        panXPx: Float,
        panYPx: Float,
        atScale: Float,
        fitWidthPx: Int,
        pageWidthPt: Double,
        pageHeightPt: Double,
        viewportWidthPx: Float,
        viewportHeightPx: Float,
    ): Pair<Float, Float> {
        val liveWidthPx = renderWidthPx(fitWidthPx, atScale)
        val liveHeightPx = heightForWidthPx(liveWidthPx, pageWidthPt, pageHeightPt)
        val boundX = panBoundPx(liveWidthPx.toFloat(), viewportWidthPx)
        val boundY = panBoundPx(liveHeightPx.toFloat(), viewportHeightPx)
        return panXPx.coerceIn(-boundX, boundX) to panYPx.coerceIn(-boundY, boundY)
    }

    /**
     * Local (screen-relative-to-viewport) scale-then-translate camera for the annotation dry/wet overlays,
     * which — unlike the page bitmap — cannot ride the bitmap's own `graphicsLayer` (androidx.ink's stroke
     * API takes a flat matrix, not a Compose layer chain, and the wet overlay in particular must never be
     * wrapped in a transform that could grow its own measured size — see the class doc's front-buffer
     * note). Derived from the SAME `transformOrigin = (0.5, 0.5)` pivot the bitmap's own `graphicsLayer`
     * scales around: a "world" point at the raster content's own center ([rasterWidthPx] / 2,
     * [rasterHeightPx] / 2) maps to the viewport's center plus [panXPx]/[panYPx]; everything else scales
     * by [zoom] (= live `scale` / `rasterScale`) around that. Returns `(translateX, translateY)` to feed a
     * `Matrix.setScale(zoom, zoom); postTranslate(tx, ty)` (or `AnnotationDryOverlay`'s equivalent
     * `pxPerMM = 1f, scale = zoom, panOffset = Offset(tx, ty)`).
     */
    fun annotationCameraTranslate(
        zoom: Float,
        rasterWidthPx: Int,
        rasterHeightPx: Int,
        viewportWidthPx: Int,
        viewportHeightPx: Int,
        panXPx: Float,
        panYPx: Float,
    ): Pair<Float, Float> {
        val tx = viewportWidthPx / 2f + panXPx - zoom * rasterWidthPx / 2f
        val ty = viewportHeightPx / 2f + panYPx - zoom * rasterHeightPx / 2f
        return tx to ty
    }
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
 * `Modifier.size` constraint semantics), just escaped from the opposite corner. That escape hatch alone is
 * NOT sufficient, though: `wrapContentSize(unbounded = true)` reports its OWN measured size back to ITS
 * parent coerced into that parent's incoming constraints, so whenever the content is smaller than the
 * viewport (any letterboxed page at rest), the reported size equals the content's own size — leaving the
 * wrapper's inner `align = Center` nothing to center against (there is no leftover room inside a
 * same-size wrapper). The OUTER pager-page `Box` (below) must therefore ALSO set `contentAlignment =
 * Center` — it, not the inner `align`, is what actually centers a page smaller than the viewport; the
 * inner `align` only takes over once `rasterScale` grows the content past the viewport and the wrapper's
 * reported size clamps down to match. Omitting the outer `contentAlignment` compiles and looks
 * plausible, but silently renders every at-rest page flush to the top-left instead of centered.
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
 * `PagedScore`'s cursor overlay, tap-to-seek, or playback-auto-follow wiring. [audioVm] and
 * [autoFollowEnabled] are accepted for that future wiring and unused here; [readerVm] IS used, for
 * [annotation]'s capture path.
 *
 * [annotation] (Task 11) anchors ink to a PAGE, not a musical position — see [PdfVerticalScore]'s own class
 * doc for the shared `PageAnchoringCore` rationale. Only one page is ever visible here, so capture always
 * knows its page already (no centroid resolve, unlike the scrolling surface) and display only ever shows
 * strokes anchored to the CURRENT page (`PagedPdfPage` builds a whole-document-length page-frame array with
 * every OTHER page's slot a zero-width placeholder, which the native side already treats as "not placeable
 * this frame"). The dry/wet overlays mount OUTSIDE the bitmap's own `graphicsLayer` (they cannot ride it —
 * see `PagedPdfPage`'s own mounting comment) using an explicit camera derived from the SAME center-anchored
 * placement (`PagedPdfLayout.annotationCameraTranslate`).
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
    /** Annotation layers + capture pipeline, owned by ReaderScreen. Null ⇒ no annotation on this surface. */
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

    // Drive the source's memory window off `currentPage` (the brief's own `setWindow` call) — a pinch
    // alone never moves it, only an actual page turn does. `currentPage` is the pager's TARGET page: it
    // flips as soon as a swipe crosses the page boundary, slightly before the fling settles on it. That
    // only means the window is (re)primed a little early, never late — harmless prefetch, not a
    // correctness issue — so this deliberately does NOT wait for `pagerState.settledPage`.
    LaunchedEffect(source, pagerState.currentPage, pageCount) {
        if (pageCount > 0) source.setWindow(pagerState.currentPage, radius = 1)
    }

    // A plain `derivedStateOf` snapshot read, NOT `scale == 1f` inlined into the `HorizontalPager` call
    // below: `scale` itself is written on every pinch frame, so reading it directly at this composable's
    // body would recompose this whole function ~60x/second for the life of a pinch gesture, even though
    // the result is a `Boolean` that only actually flips twice per gesture (zoom past 1x, and back).
    // `derivedStateOf` re-runs the same per-frame read but only PUBLISHES — and so only recomposes readers
    // on — an actual change to that `Boolean` (lesson from Task 7's zoom-path fix rounds). `annotationMode`
    // is a `remember` key (not read directly inside the block): it changes rarely (an explicit tool
    // toggle), so rebuilding the wrapper on it costs nothing, but the block itself must close over a LIVE
    // value — `PagedScore.kt:207`'s own `scale == 1f && !annotationMode` is the reference this mirrors:
    // annotating freezes the pager too, or a horizontal stroke would turn the page under the finger.
    val annotationMode = annotation?.annotationMode == true
    val swipeEnabled by remember(annotationMode) { derivedStateOf { scaleState.floatValue == 1f && !annotationMode } }

    Box(Modifier.fillMaxSize().onSizeChanged { viewportSize = it }) {
        if (pageCount == 0) return@Box

        HorizontalPager(
            state = pagerState,
            // Only swipe at unit zoom AND not annotating; while zoomed OR annotating, the gesture pans / draws
            // instead (`PagedScore` parity).
            userScrollEnabled = swipeEnabled,
            modifier = Modifier.fillMaxSize(),
        ) { pageIndex ->
            PagedPdfPage(
                index = pageIndex,
                pageCount = pageCount,
                pageWidthPt = state.pageWidthsPt[pageIndex],
                pageHeightPt = state.pageHeightsPt[pageIndex],
                viewportSize = viewportSize,
                source = source,
                scaleState = scaleState,
                rasterScaleState = rasterScaleState,
                panOffsetState = panOffsetState,
                readerVm = readerVm,
                annotation = annotation,
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
    /** Whole document's page count — sizes the [PageFramesWire] array [pdfAnnotation]'s display/capture
     * paths pass to the native PDF annotation entry points (positionally indexed by page). */
    pageCount: Int,
    pageWidthPt: Double,
    pageHeightPt: Double,
    viewportSize: IntSize,
    source: PdfPageSource,
    scaleState: MutableFloatState,
    rasterScaleState: MutableFloatState,
    panOffsetState: MutableState<Offset>,
    readerVm: ReaderViewModel,
    /** Annotation layers + capture pipeline, owned by ReaderScreen. Null ⇒ no annotation on this surface. */
    annotation: AnnotationSurfaceState?,
) {
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    var scale by scaleState
    var panOffset by panOffsetState
    val annotationMode = annotation?.annotationMode == true

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

    // This page's own raster frame (origin at its own top-left — the SAME "world" space the annotation
    // camera below places at the viewport center) — null until the raster geometry is known. Only THIS
    // page's slot is populated in the whole-document-length array `nativePdfAnnotationDisplayTransforms`
    // wants (positionally indexed by page): every other page is off-screen in paged mode, so its slot
    // stays a zero-width placeholder, which the native side already treats as "not placeable this frame"
    // (`PageAnchoringCore.displayTransform`'s own `width > 0` guard) — exactly right, since only strokes on
    // THIS page should render while it's the one visible.
    val pageFrame = if (rasterWidthPx > 0 && rasterHeightPx > 0) {
        PageFrameWire(x = 0.0, y = 0.0, width = rasterWidthPx.toDouble(), height = rasterHeightPx.toDouble())
    } else {
        null
    }
    val pageFrames = remember(pageCount, index, pageFrame) {
        List(pageCount) { i -> if (i == index && pageFrame != null) pageFrame else PageFrameWire(0.0, 0.0, 0.0, 0.0) }
    }
    val resolveDisplayTransforms = remember(pageFrames) {
        { drawings: List<DrawingAnchorWire> ->
            ReaderAnnotationJNI.pdfDisplayTransforms(
                encodeWireArray(drawings, DrawingAnchorWireCodec::encodePayload),
                PageFramesWireCodec.encode(PageFramesWire(pageFrames)),
            )
        }
    }
    // Local copy of the shared `annotation` bundle with a page-known capture (see `PdfVerticalScore`'s own
    // equivalent for the fuller rationale — same reasoning, just "this page IS the visible one" instead of
    // resolving from a centroid). Rebuilt fresh every recomposition; see that same doc for why that's fine.
    val pdfAnnotation = annotation?.let { base ->
        AnnotationSurfaceState(
            annotationMode = base.annotationMode,
            drawings = base.drawings,
            layoutGeneration = base.layoutGeneration,
            colorRGBA = base.colorRGBA,
            widthMm = base.widthMm,
            eraserMode = base.eraserMode,
            onEraseGesture = base.onEraseGesture,
            inkHandoff = base.inkHandoff,
            onStrokeCaptured = { stroke, onCommitted ->
                val capturedColorRGBA = base.colorRGBA
                val capturedWidthMm = base.widthMm
                val frame = pageFrame
                scope.launch(Dispatchers.Default) {
                    val drawing = frame?.let {
                        PdfAnnotationCaptureController.capture(
                            stroke = stroke,
                            tool = AnnotationSurfaceState.WET_STROKE_TOOL,
                            colorRGBA = capturedColorRGBA,
                            baseWidthSp = capturedWidthMm,
                            pageIndex = index,
                            pageFrame = it,
                        )
                    }
                    drawing?.let { readerVm.addDrawing(it) }
                    withContext(Dispatchers.Main) { onCommitted(drawing) }
                }
            },
        )
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.White)
            .clipToBounds()
            // Pinch-zoom + pan. Lives INSIDE the pager page (not a sibling overlay of the whole pager), so
            // at scale == 1 a single-finger drag is left unconsumed and reaches `HorizontalPager` itself —
            // `PagedScore`'s exact same trick, see its own comment.
            .pointerInput(index, fitWidthPx, annotationMode) {
                if (fitWidthPx <= 0) return@pointerInput
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    // Clamps a candidate pan (one gesture-local helper, closing over `size`/`fitWidthPx`/
                    // the page's own point size) to what `PagedPdfLayout.clampPan` allows AT `atScale` —
                    // shared by both the two-finger and one-finger branches below.
                    fun clamp(p: Offset, atScale: Float): Offset {
                        val (x, y) = PagedPdfLayout.clampPan(
                            panXPx = p.x,
                            panYPx = p.y,
                            atScale = atScale,
                            fitWidthPx = fitWidthPx,
                            pageWidthPt = pageWidthPt,
                            pageHeightPt = pageHeightPt,
                            viewportWidthPx = size.width.toFloat(),
                            viewportHeightPx = size.height.toFloat(),
                        )
                        return Offset(x, y)
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
                            // A single-finger drag while annotating is a stroke, not a pan — the wet
                            // overlay owns it (`PagedScore` parity; two-finger pinch above still applies:
                            // the wet layer cancels its stroke and hands the gesture back).
                        } else if (activeCount == 1 && scale > 1f && !annotationMode) {
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
        // MUST be `Center`, not the default `TopStart` — this is what actually centers a page smaller
        // than the viewport (the wrapper Box below only takes over once the content overflows it). See
        // the class doc's "That escape hatch alone is NOT sufficient" paragraph for the full reasoning.
        contentAlignment = Alignment.Center,
    ) {
        // Escapes this Box's `fillMaxSize` bound so a raster page wider/taller than the viewport (any
        // `scale > 1`) isn't clamped back down to the viewport's own size by plain `Modifier.size`
        // constraint semantics — see the class doc. `align = Center` (not `PdfVerticalScore`'s `TopStart`)
        // matches this surface's centered content.
        Box(
            remember(scaleState, rasterScaleState, panOffsetState) {
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

        if (pdfAnnotation != null && rasterWidthPx > 0 && rasterHeightPx > 0) {
            // Own camera, OUTSIDE the bitmap's own `graphicsLayer` — androidx.ink's stroke API takes a flat
            // matrix, not a Compose layer chain, and the wet overlay in particular must never be wrapped in
            // a transform that could grow its own measured size (see `AnnotationLayers`' front-buffer
            // note). `annotationCameraTranslate` derives the SAME center-anchored placement the bitmap's
            // own `graphicsLayer` above gets (matching `transformOrigin = (0.5, 0.5)` + `panOffset`), just
            // expressed as an explicit scale-then-translate a `Matrix`/`AnnotationDryOverlay` can consume —
            // see that function's own doc. Sized to this OUTER viewport-sized Box (unlike the bitmap
            // escape-hatch Box above), matching `PagedScore`'s own page-mode overlays: "a page IS
            // viewport-sized, so even at the 8x zoom ceiling the front buffer stays far inside the 65536 px
            // limit" — no wet-window clamping is needed here (unlike the scrolling PDF surface).
            val zoom = scaleState.floatValue / rasterScaleState.floatValue
            val (tx, ty) = PagedPdfLayout.annotationCameraTranslate(
                zoom = zoom,
                rasterWidthPx = rasterWidthPx,
                rasterHeightPx = rasterHeightPx,
                viewportWidthPx = viewportSize.width,
                viewportHeightPx = viewportSize.height,
                panXPx = panOffset.x,
                panYPx = panOffset.y,
            )
            AnnotationLayers(
                resolveDisplayTransforms = resolveDisplayTransforms,
                annotation = pdfAnnotation,
                pxPerMM = 1f,
                scale = zoom,
                isDrawing = false,
                dryPanOffset = Offset(tx, ty),
                dryModifier = Modifier.fillMaxSize(),
                wetWorldToScreen = remember(zoom, tx, ty) {
                    Matrix().apply {
                        setScale(zoom, zoom)
                        postTranslate(tx, ty)
                    }
                },
                wetModifier = Modifier.fillMaxSize(),
            )
        }
    }
}
