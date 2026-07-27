package com.keynumber.folino.reader.pdf

import android.graphics.Bitmap
import android.graphics.Matrix
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.DrawingAnchorWire
import com.keynumber.folino.reader.DrawingAnchorWireCodec
import com.keynumber.folino.reader.PageFrameWire
import com.keynumber.folino.reader.PageFramesWire
import com.keynumber.folino.reader.PageFramesWireCodec
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
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Pages kept rasterized on either side of the current one — mirrors the `radius`
 * [PdfPageSource.setWindow] is driven with below.
 */
private const val PDF_WINDOW_RADIUS = 1

/** Gap between consecutive pages. */
private val PAGE_GAP = 12.dp

/** Breathing room above the first page and below the last one (iOS-parity feel with [ReadyScore]'s `vPadPx`). */
private val TOP_BOTTOM_PAD = 16.dp

/**
 * Pure geometry for laying out a PDF's pages in a single vertically scrolling column, every page
 * rendered at the same on-screen WIDTH ([renderWidthPx]) regardless of its own point size — height
 * follows from that page's own aspect ratio, so a landscape page in an otherwise-portrait score isn't
 * forced to match its neighbors' height. Split out from [PdfVerticalScore] for the same reason
 * [PdfPageWindow]/[PdfRenderInstall] are split out of `PdfPageSource.kt`: this is plain `Int`/`Float`
 * arithmetic, unit-testable off-device, while the composable itself needs a real Compose + `PdfRenderer`
 * environment.
 */
internal object PdfVerticalLayout {

    /** The pixel width every page is rendered/displayed at, for a given [viewportWidthPx] and pinch [scale]. */
    fun renderWidthPx(viewportWidthPx: Int, scale: Float): Int =
        (viewportWidthPx * scale).roundToInt().coerceAtLeast(1)

    /**
     * On-screen height (px) of each page, given the document's per-page point sizes ([widthsPt] /
     * [heightsPt], as `PdfRenderer` reports them) and the width every page is rendered at
     * ([renderWidthPx]) — height follows each page's own aspect ratio.
     */
    fun pageHeightsPx(widthsPt: List<Double>, heightsPt: List<Double>, renderWidthPx: Int): FloatArray =
        FloatArray(widthsPt.size) { i -> (renderWidthPx.toDouble() * heightsPt[i] / widthsPt[i]).toFloat() }

    /**
     * Same computation as [pageHeightsPx], writing into a caller-provided [dest] instead of allocating a
     * new array. [PdfVerticalScore]'s `derivedStateOf` block re-derives this on every relevant snapshot
     * read (every scroll AND pinch frame) purely to compute an `Int` page index that is thrown away
     * immediately after — a fresh `FloatArray` there would be per-frame garbage for no benefit.
     *
     * **[dest] must be sized EXACTLY [widthsPt]`.size` — not merely "at least."** This is a strict
     * contract, not a convenience minimum: only indices `0 until widthsPt.size` are written, so a
     * LARGER [dest] left over from a previous, longer document would keep stale trailing entries that
     * [currentPageIndex] (which walks `pageHeightsPx.indices`) would then read back as phantom pages
     * past the real end of the document. [PdfVerticalScore] satisfies this by `remember`ing the scratch
     * array keyed on `state` (`remember(state) { FloatArray(pageCount) }`), so a page-count change (a
     * different PDF) always reallocates a correctly-sized buffer rather than reusing a stale one.
     */
    fun pageHeightsPxInto(dest: FloatArray, widthsPt: List<Double>, heightsPt: List<Double>, renderWidthPx: Int) {
        for (i in widthsPt.indices) {
            dest[i] = (renderWidthPx.toDouble() * heightsPt[i] / widthsPt[i]).toFloat()
        }
    }

    /**
     * The live, on-screen inter-page gap (px), given the page `Column`'s raw [gapPx] and the pinch/raster
     * zoom ratio ([scale] / [rasterScale]) that [PdfVerticalScore]'s `graphicsLayer` bridge applies (see
     * its class doc). `Arrangement.spacedBy` — and so every on-screen gap — lives INSIDE that layer, so
     * anything computing scroll-extent or scroll-position math in the OUTER, live-sized coordinate space
     * must use THIS value in place of the raw [gapPx], or the two drift apart by exactly
     * `(scale/rasterScale - 1) * gapPx` per gap during a pinch (self-corrects once `rasterScale` catches
     * up to `scale` at gesture end). Top/bottom padding does NOT need this correction — see
     * `focalAdjustedOffset`'s doc for why that one is a fixed, unscaled leading offset instead.
     */
    fun liveGapPx(gapPx: Float, scale: Float, rasterScale: Float): Float = gapPx * (scale / rasterScale)

    /**
     * Total scrollable content height (px): every page plus one [gapPx] gap between each consecutive
     * pair, plus [topPadPx] / [bottomPadPx] breathing room at the ends. [bottomPadPx] is where a caller
     * folds in extra clearance for a floating control (mirrors [ReadyScore]'s `bottomContentPad`). A
     * caller passing a live-scale-based `pageHeightsPx` array (e.g. `PdfVerticalScore`'s `liveHeightsPx`)
     * should pass [liveGapPx]'s result as [gapPx], not the raw gap — see that function's doc for why.
     */
    fun totalContentHeightPx(pageHeightsPx: FloatArray, gapPx: Float, topPadPx: Float, bottomPadPx: Float): Float {
        if (pageHeightsPx.isEmpty()) return topPadPx + bottomPadPx
        return topPadPx + bottomPadPx + pageHeightsPx.sum() + gapPx * (pageHeightsPx.size - 1)
    }

    /**
     * The page whose band contains the viewport's vertical CENTER, given the current scroll offset
     * ([scrollPx]) and [viewportHeightPx]. This is what drives [PdfPageSource.setWindow] — deliberately
     * scroll-position-based rather than pinch-scale-based, so a pinch alone (no scroll) never moves the
     * window. Clamped to the document; returns 0 for an empty document (real call sites never render
     * with `pageCount == 0`, but the function stays total rather than partial). Same [gapPx] caveat as
     * [totalContentHeightPx]: pass [liveGapPx]'s result when [pageHeightsPx] is live-scale-based, so this
     * walks the SAME page boundaries the scroll extent was declared with.
     */
    fun currentPageIndex(
        scrollPx: Float,
        viewportHeightPx: Float,
        pageHeightsPx: FloatArray,
        gapPx: Float,
        topPadPx: Float,
    ): Int {
        if (pageHeightsPx.isEmpty()) return 0
        val centerY = scrollPx + viewportHeightPx / 2f
        var y = topPadPx
        for (i in pageHeightsPx.indices) {
            val bottom = y + pageHeightsPx[i]
            if (centerY < bottom || i == pageHeightsPx.lastIndex) return i
            y = bottom + gapPx
        }
        return pageHeightsPx.lastIndex
    }

    /**
     * Column-local (no top padding) Y origin of each page's top edge, given the same [pageHeightsPx] /
     * [gapPx] this layout already threads through [totalContentHeightPx] / [currentPageIndex] — the
     * page-anchored annotation pipeline needs each page's own frame both to resolve which page a wet
     * stroke's centroid landed on ([pageIndexForY]) and to project stored ink back onto the page it
     * currently occupies (the raster page-frame list `PdfVerticalScore` feeds
     * `ReaderAnnotationJNI.pdfDisplayTransforms`).
     */
    fun pageOriginsPx(pageHeightsPx: FloatArray, gapPx: Float): FloatArray {
        val origins = FloatArray(pageHeightsPx.size)
        var y = 0f
        for (i in pageHeightsPx.indices) {
            origins[i] = y
            y += pageHeightsPx[i] + gapPx
        }
        return origins
    }

    /**
     * The page whose band contains Column-local [y] (matching [pageOriginsPx]), else the page whose
     * vertical extent is nearest — covers a centroid landing in the inter-page gap. Mirrors shared Swift
     * `PageAnchoringCore.pageIndex(forCentroid:pageFrames:)`'s own vertical fallback: distance is measured
     * to a page's nearest edge (zero while [y] is inside its band), and a tie resolves to the earlier page
     * (`<`, not `<=`, keeps the first minimum found). Returns 0 for an empty document; real call sites
     * never resolve a stroke's page with `pageCount == 0` (there is nothing to draw on).
     */
    fun pageIndexForY(y: Float, pageHeightsPx: FloatArray, gapPx: Float): Int {
        if (pageHeightsPx.isEmpty()) return 0
        val origins = pageOriginsPx(pageHeightsPx, gapPx)
        var best = 0
        var bestDist = Float.MAX_VALUE
        for (i in pageHeightsPx.indices) {
            val top = origins[i]
            val bottom = top + pageHeightsPx[i]
            val clampedY = y.coerceIn(top, bottom)
            val d = abs(clampedY - y)
            if (d < bestDist) {
                bestDist = d
                best = i
            }
        }
        return best
    }
}

/**
 * The vertical-continuous PDF reading surface: every page of [state], one below the other, scrolled as
 * one column. Modeled on [ReadyScore]'s zoom architecture (`ReaderScreen.kt`) — read that first — because
 * its two-stage zoom is load-bearing here too, and reproduced the same way: [scale] is where the fingers
 * are RIGHT NOW, [rasterScale] is the zoom [source] last rendered bitmaps at, and the two are bridged by a
 * `remember`ed `graphicsLayer` whose `scaleX`/`scaleY` read `scaleState`/`rasterScaleState` INSIDE the layer
 * block — exactly [ReadyScore]'s `scoreSurfaceModifier` shape, just wrapping this surface's page `Column`
 * instead of a `BandedScorePage`. That split is what keeps a pinch off the per-page-item recompute path:
 * every page `Box` is measured/positioned from [rasterScale] (stable for the whole gesture — see
 * `pageHeightsPxRaster` below), so [PdfPageItem] gets the SAME width/height arguments on every pinch frame,
 * and the layer transform alone covers the live zoom, exactly like the outer `contentWidthPx`/
 * `contentHeightPx` Box below tracks the live [scale] for correct scroll-extent math while the inner
 * content stays put. Only [rasterScale] feeds [PdfVerticalLayout.renderWidthPx] for the actual
 * [PdfPageSource.bitmap] request width, and it only moves once, when a pinch gesture ends — never per
 * frame — so a pinch never touches [PdfPageSource] at all.
 *
 * Unlike [ReadyScore], there is no `scoreHandle` yet for a PDF (the parsed score arrives in Task 12), so
 * this surface has none of [ReadyScore]'s cursor overlay, tap-to-seek, or playback-auto-follow gestures —
 * there is nothing yet for them to follow. [audioVm] and [autoFollowEnabled] are accepted for that future
 * wiring and unused here; [readerVm] IS used, for [annotation]'s capture path (`readerVm.addDrawing`).
 *
 * [annotation] (Task 11) anchors ink to a PAGE, not a musical position: page index plus geometry
 * normalized to a fraction of that page's own width, so the same stroke re-renders correctly at any zoom
 * (the zoom factor cancels — see `ReaderAnnotationCore.PageAnchoringCore`, the shared Swift this and iOS's
 * PDF surfaces both call through). The dry/wet overlays mount OUTSIDE the page `Column`'s own
 * `graphicsLayer` (mirroring [ReadyScore]'s own ink overlays, never the score's live-record path) and use
 * their OWN camera: `pxPerMM = 1f` (raster page frames are already in px, no mm conversion) and
 * `scale = zoom` (the SAME `scaleState / rasterScaleState` ratio the Column's `graphicsLayer` reads), so
 * moving the ink overlays exactly tracks the zoomed Column without re-deriving page geometry on a live
 * pinch frame — the actual `pdfDisplayTransforms`/capture JNI calls key off [pageFramesRaster], which only
 * changes at a raster-scale settle (window move or pinch end), never per frame.
 */
@Composable
internal fun PdfVerticalScore(
    state: ReaderState.ReadyPdf,
    source: PdfPageSource,
    audioVm: ReaderAudioViewModel,
    readerVm: ReaderViewModel,
    bottomContentPad: Dp = 0.dp,
    /** Annotation layers + capture pipeline, owned by ReaderScreen. Null ⇒ no annotation on this surface. */
    annotation: AnnotationSurfaceState? = null,
    /** Reserved for Task 12's playback auto-follow, once a PDF has a parsed score to follow. Unused here. */
    autoFollowEnabled: Boolean = true,
) {
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    // Held as the state object (not just through `by`) for the same reason `ReadyScore` does: read
    // directly, a fresh value on every pinch frame — that is fine here because reading it only resizes
    // ONE Box (the scroll-extent Box below), not the per-page items; see the class doc.
    val scaleState = remember { mutableFloatStateOf(1f) }
    var scale by scaleState
    // The zoom the currently-displayed bitmaps (and the page `Column`'s own layout) are actually
    // rasterized/sized at, as opposed to `scale`, which is where the fingers are right now. See the
    // class doc: only THIS feeds the `PdfPageSource.bitmap` request width and the page items' own
    // sizes, and only a gesture end (fingers-up, below) moves it.
    val rasterScaleState = remember { mutableFloatStateOf(1f) }
    var rasterScale by rasterScaleState

    val vScroll = rememberScrollState()
    val hScroll = rememberScrollState()

    val vPadPx = with(density) { TOP_BOTTOM_PAD.toPx() }
    val gapPx = with(density) { PAGE_GAP.toPx() }
    // Extra clearance BEYOND the ordinary bottom breathing room (`vPadPx`, folded in below), so the last
    // page can scroll out from under a floating control when the seek bar is off — mirrors `ReadyScore`'s
    // `bottomContentPad`.
    val extraBottomPadPx = with(density) { bottomContentPad.toPx() }

    val pageCount = state.pageCount

    // Nothing below is meaningful until the first layout pass reports a real width — before that,
    // `viewportSize.width == 0` and every page would otherwise size/request itself at the helper's
    // degenerate 1px floor (see `PdfVerticalLayout.renderWidthPx`). Mirrors `ReadyScore`'s own
    // `viewportSize.width > 0` guard on `fitPxPerMM`.
    val viewportKnown = viewportSize.width > 0

    // The bitmap render width to request at the NEXT settle, and the width every page `Box` is actually
    // measured at — `rasterScale`, never the live `scale`, so neither a re-raster nor a per-page relayout
    // happens mid-gesture. Zero (not the helper's 1px floor) until the viewport is known.
    val rasterWidthPx = if (viewportKnown) PdfVerticalLayout.renderWidthPx(viewportSize.width, rasterScale) else 0
    // Recomputed only when `rasterWidthPx` actually changes (i.e., once per gesture, on settle) — this is
    // what makes every `PdfPageItem` call below receive the SAME `widthDp`/`heightDp` on every pinch frame.
    val pageHeightsPxRaster = remember(state, rasterWidthPx) {
        PdfVerticalLayout.pageHeightsPx(state.pageWidthsPt, state.pageHeightsPt, rasterWidthPx)
    }

    // Every page's Column-local (no top padding) frame at raster scale — annotation geometry, NOT the
    // outer live-scaled content box. Recomputed only alongside `pageHeightsPxRaster` (a raster-scale
    // settle or window move), never on a live pinch frame — the ink overlays' own camera folds in the
    // live/raster zoom ratio separately (see the class doc), so this stays cheap to recompute.
    val pageFramesRaster = remember(pageHeightsPxRaster, gapPx) {
        val origins = PdfVerticalLayout.pageOriginsPx(pageHeightsPxRaster, gapPx)
        List(pageCount) { i ->
            PageFrameWire(
                x = 0.0,
                y = origins[i].toDouble(),
                width = rasterWidthPx.toDouble(),
                height = pageHeightsPxRaster[i].toDouble(),
            )
        }
    }
    // Injected into `AnnotationDryOverlay` (via `AnnotationLayers`) as its `resolveDisplayTransforms` —
    // remembered on `pageFramesRaster`'s own identity so the native round trip only re-runs when the
    // raster geometry actually changes, not on every recomposition (this composable's whole body
    // recomposes on every pinch/scroll frame — see `scale`'s own doc above).
    val resolveDisplayTransforms = remember(pageFramesRaster) {
        { drawings: List<DrawingAnchorWire> ->
            ReaderAnnotationJNI.pdfDisplayTransforms(
                encodeWireArray(drawings, DrawingAnchorWireCodec::encodePayload),
                PageFramesWireCodec.encode(PageFramesWire(pageFramesRaster)),
            )
        }
    }

    // Live (per-frame during a pinch) content-box geometry: cheap arithmetic recomputed directly from
    // `scale` every frame — same trade-off `ReadyScore`'s own outer content Box makes — so the scrollable
    // extent (and `isZoomed`) always track what's on screen while the fingers are down. This is ONLY used
    // for the outer sized Box below; the actual page items are sized from `rasterWidthPx` above.
    val liveWidthPx = if (viewportKnown) PdfVerticalLayout.renderWidthPx(viewportSize.width, scale) else 0
    val liveHeightsPx = remember(state, liveWidthPx) {
        PdfVerticalLayout.pageHeightsPx(state.pageWidthsPt, state.pageHeightsPt, liveWidthPx)
    }
    val contentWidthPx = liveWidthPx.toFloat()
    // The on-screen gap is `Arrangement.spacedBy(PAGE_GAP)` INSIDE the page `Column`'s `graphicsLayer`
    // (see the class doc and `PdfVerticalLayout.liveGapPx`'s doc), so the declared scroll extent must use
    // the LIVE gap, not the raw one, or it drifts from what's actually on screen mid-pinch. `vPadPx` does
    // NOT get the same treatment — it's the fixed leading offset `focalAdjustedOffset` already treats as
    // constant (padding sits OUTSIDE the graphicsLayer in the modifier chain below, so it never scales).
    val contentHeightPx = PdfVerticalLayout.totalContentHeightPx(
        liveHeightsPx,
        gapPx = PdfVerticalLayout.liveGapPx(gapPx, scale, rasterScale),
        topPadPx = vPadPx,
        bottomPadPx = vPadPx + extraBottomPadPx,
    )
    val isZoomed = contentWidthPx > viewportSize.width + 0.5f

    // Reused every re-derivation below instead of allocating a fresh `FloatArray` per scroll/pinch frame
    // — see `PdfVerticalLayout.pageHeightsPxInto`'s doc.
    val liveHeightsScratch = remember(state) { FloatArray(pageCount) }

    // `currentPage` must be read from `vScroll.value` (a per-scroll-frame snapshot value) WITHOUT making
    // the whole surface recompose on every scroll tick — wrapped in `derivedStateOf` so a reader (the
    // `LaunchedEffect` below, and `isNearCurrentPage` per item) only recomposes when the computed page
    // index actually changes. The live-`scale`-based geometry is recomputed INSIDE the lambda (not
    // captured from `contentWidthPx`/`liveWidthPx` above) so this stays correct across pinch frames without
    // re-deriving the state itself: `derivedStateOf`'s block reruns on every relevant snapshot read
    // (`vScroll.value`, `viewportSize`, `scaleState.floatValue`, `rasterScaleState.floatValue`), it just
    // only PUBLISHES a change when the resulting `Int` differs. This mirrors `ReadyScore`, which never
    // reads `vScroll.value`/`hScroll.value` directly in its body either — only inside gesture callbacks
    // and effects. Uses the SAME `liveGapPx` correction as `contentHeightPx` above, so this walks page
    // boundaries consistent with whatever extent the scroll container was actually given.
    val currentPage by remember(state, gapPx, vPadPx) {
        derivedStateOf {
            // NOT a pure function of its inputs: it mutates `liveHeightsScratch` (a `remember`ed, shared
            // buffer) as a side effect on every re-derivation. That is safe ONLY because `derivedStateOf`
            // blocks, like the rest of Compose's snapshot system, are read/run on the composition thread
            // (the main thread here) — there is no concurrent writer this could race with. If a future
            // change ever moved this computation off that thread (e.g. into a background-dispatched
            // effect), this mutation would need its own synchronization.
            val liveWidth = if (viewportSize.width > 0) {
                PdfVerticalLayout.renderWidthPx(viewportSize.width, scaleState.floatValue)
            } else {
                0
            }
            PdfVerticalLayout.pageHeightsPxInto(
                liveHeightsScratch,
                state.pageWidthsPt,
                state.pageHeightsPt,
                liveWidth,
            )
            PdfVerticalLayout.currentPageIndex(
                scrollPx = vScroll.value.toFloat(),
                viewportHeightPx = viewportSize.height.toFloat(),
                pageHeightsPx = liveHeightsScratch,
                gapPx = PdfVerticalLayout.liveGapPx(gapPx, scaleState.floatValue, rasterScaleState.floatValue),
                topPadPx = vPadPx,
            )
        }
    }

    // Drive the source's memory window off scroll position (via `currentPage`), not off `scale` — a
    // pinch alone never moves it, only scrolling past a page boundary does. Re-runs only when
    // `currentPage` actually changes value (a plain `Int` key backed by `derivedStateOf` above).
    LaunchedEffect(source, currentPage, pageCount, viewportKnown) {
        if (pageCount > 0 && viewportKnown) source.setWindow(currentPage, radius = PDF_WINDOW_RADIUS)
    }

    val annotationMode = annotation?.annotationMode == true

    // A local copy of the shared `annotation` bundle with a PDF-specific `onStrokeCaptured`: the shared
    // one (built once in `ReaderScreen`) resolves a musical anchor via `scoreHandle`, which is always null
    // for a PDF (Task 12 hasn't landed a parsed score for one yet). Every other field is forwarded
    // unchanged — color/width/eraser state, the committed layer, the wet↔dry handoff queue all come from
    // the SAME shared bundle every surface uses. Rebuilt fresh every recomposition (no `remember`): the
    // base `annotation` itself is a fresh object every `ReaderScreen` recomposition already (see its own
    // construction site), so memoizing here would buy nothing, and `onStrokeCaptured` is only ever invoked
    // from a finished-stroke callback (not a `LaunchedEffect` key), so a fresh closure every time is fine —
    // exactly how `AnnotationWetOverlay` already expects it (`rememberUpdatedState` there covers freshness).
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
                val heights = pageHeightsPxRaster
                val frames = pageFramesRaster
                scope.launch(Dispatchers.Default) {
                    val drawing = PdfAnnotationCaptureController.captureResolvingPage(
                        stroke = stroke,
                        tool = AnnotationSurfaceState.WET_STROKE_TOOL,
                        colorRGBA = capturedColorRGBA,
                        baseWidthSp = capturedWidthMm,
                    ) { y ->
                        val index = PdfVerticalLayout.pageIndexForY(y, heights, gapPx)
                        frames.getOrNull(index)?.let { index to it }
                    }
                    drawing?.let { readerVm.addDrawing(it) }
                    withContext(Dispatchers.Main) { onCommitted(drawing) }
                }
            },
        )
    }

    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged { viewportSize = it }
            // Pinch zoom only: a live two-finger contact is consumed here; a single-finger drag falls
            // through untouched to the scroll modifiers below (native fling + overscroll).
            .pointerInput(viewportSize.width) {
                if (viewportSize.width <= 0) return@pointerInput
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        if (event.changes.count { it.pressed } >= 2) {
                            val zoom = event.calculateZoom()
                            if (zoom != 1f) {
                                val centroid = event.calculateCentroid(useCurrent = true)
                                val newScale = (scale * zoom).coerceIn(1f, 8f)
                                val ratio = newScale / scale
                                if (ratio != 1f && !centroid.x.isNaN() && !centroid.y.isNaN()) {
                                    val newX = focalAdjustedOffset(hScroll.value.toFloat(), centroid.x, ratio)
                                    val newY = focalAdjustedOffset(vScroll.value.toFloat(), centroid.y, ratio, vPadPx)
                                    scale = newScale
                                    // scrollTo is a suspend fun; PointerInputScope's coroutine scope
                                    // doesn't allow arbitrary launches, so use the composable-level one.
                                    scope.launch { hScroll.scrollTo(newX.toInt().coerceAtLeast(0)) }
                                    scope.launch { vScroll.scrollTo(newY.toInt().coerceAtLeast(0)) }
                                }
                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                            }
                        }
                    } while (event.changes.any { it.pressed })
                    // Fingers up: the ONE re-raster point for this whole gesture. Every page still
                    // showing bitmaps from before the pinch will re-request at the new width the next
                    // time its own effect runs (see `PdfPageItem` below) — skipped entirely if the scale
                    // didn't move, so an ordinary tap or scroll costs nothing here.
                    if (rasterScaleState.floatValue != scaleState.floatValue) {
                        rasterScaleState.floatValue = scaleState.floatValue
                    }
                }
            },
        contentAlignment = Alignment.TopStart,
    ) {
        // While annotating, scrolling is off entirely — a single-finger drag is the wet overlay's to
        // consume as a stroke, not a scroll. `enabled = false`, not a dropped modifier: `ReadyScore`'s own
        // `scrollEnabled` doc explains why (preserves the scroll offset and the scrolled content's own
        // layer instead of collapsing back to the top / losing it on every annotate toggle). A 2-finger
        // pinch still reaches the always-installed pointerInput above regardless.
        val scrollEnabled = !annotationMode
        val scrollModifier = if (isZoomed) {
            Modifier
                .verticalScroll(vScroll, enabled = scrollEnabled)
                .horizontalScroll(hScroll, enabled = scrollEnabled)
        } else {
            Modifier.verticalScroll(vScroll, enabled = scrollEnabled)
        }

        Box(scrollModifier) {
            // Sized from the LIVE `scale` — this is what the scroll container measures its extent
            // against, so it must track the pinch every frame for the scrollbar/overscroll bounds to
            // stay correct. Its child below is sized at `rasterScale` instead and bridged by a layer
            // transform, exactly like `ReadyScore`'s outer content Box vs. its `scoreSurfaceModifier`.
            Box(
                Modifier.size(
                    width = with(density) { contentWidthPx.toDp() },
                    height = with(density) { contentHeightPx.toDp() },
                ),
            ) {
                // Remembered so `scaleState`/`rasterScaleState` are read INSIDE the `graphicsLayer` block
                // (layer phase) rather than captured as a composed value — a fresh Modifier instance here
                // would make every `PdfPageItem` call below un-skippable for the same reason `ReadyScore`
                // avoids it for `BandedScorePage`. The whole `Column` (already sized/positioned at
                // `rasterScale`, via `pageHeightsPxRaster`) is stretched by `zoom` to match the live-`scale`
                // box above; identity once `rasterScale` catches up to `scale` at gesture end.
                //
                // `wrapContentSize(unbounded = true, …)` is NOT part of `ReadyScore`'s own shape — it has
                // no equivalent there and is required for a different reason than anything above. The
                // enclosing Box just above is fixed at the LIVE `contentWidthPx`/`contentHeightPx`; without
                // `unbounded = true`, THIS Column (measured at `rasterScale`) would be constrained to fit
                // inside that live-sized parent by plain `Modifier.size` semantics — fine while zooming IN
                // (there's slack, since raster < live), but on a zoom OUT after a settle (raster > live),
                // every page would be squeezed to the smaller live width and then the `graphicsLayer` would
                // scale that ALREADY-squeezed size a second time, and the Column's own measured height,
                // now exceeding the parent's finite `maxHeight`, would clamp — collapsing trailing pages to
                // zero height. `unbounded = true` measures the Column (and everything below it in this
                // chain, including the padding) with infinite constraints, so it always reaches its true
                // raster-based natural size regardless of what the live-sized parent declares; `align =
                // Alignment.TopStart` places that (possibly larger) real content flush at (0, 0), matching
                // `transformOrigin`. The reported size back to the parent stays coerced to the parent's own
                // bounds (harmless — nothing reads it) while the ACTUAL child is free to overflow visually,
                // which is exactly what the `graphicsLayer` then needs to scale correctly. See
                // `PdfVerticalLayoutTest` / the fix report in `task-7-report.md` for the arithmetic this
                // was verified against.
                val columnModifier = remember(vPadPx, density) {
                    Modifier
                        .wrapContentSize(align = Alignment.TopStart, unbounded = true)
                        .padding(top = with(density) { vPadPx.toDp() })
                        .graphicsLayer {
                            val zoom = scaleState.floatValue / rasterScaleState.floatValue
                            scaleX = zoom
                            scaleY = zoom
                            transformOrigin = TransformOrigin(0f, 0f)
                        }
                }
                Column(
                    modifier = columnModifier,
                    verticalArrangement = Arrangement.spacedBy(PAGE_GAP),
                ) {
                    val widthDp = with(density) { rasterWidthPx.toDp() }
                    for (i in 0 until pageCount) {
                        key(i) {
                            PdfPageItem(
                                index = i,
                                widthDp = widthDp,
                                heightDp = with(density) { pageHeightsPxRaster[i].toDp() },
                                source = source,
                                rasterWidthPx = rasterWidthPx,
                                isNearCurrentPage = abs(i - currentPage) <= PDF_WINDOW_RADIUS,
                            )
                        }
                    }
                }

                pdfAnnotation?.let { an ->
                    // Own camera, OUTSIDE the Column's `graphicsLayer` — never wrap the wet (androidx.ink)
                    // overlay in a Compose transform (see the class doc and `AnnotationLayers`' own front-
                    // buffer note); `zoom` matches the Column's own live/raster ratio so both track the
                    // same visual zoom without the ink path ever re-deriving page geometry mid-pinch.
                    val zoom = scaleState.floatValue / rasterScaleState.floatValue
                    AnnotationLayers(
                        resolveDisplayTransforms = resolveDisplayTransforms,
                        annotation = an,
                        pxPerMM = 1f,
                        scale = zoom,
                        isDrawing = false,
                        dryPanOffset = Offset.Zero,
                        dryModifier = Modifier
                            .fillMaxSize()
                            .padding(top = with(density) { vPadPx.toDp() }),
                        // Viewport-height-clamped (constraint: androidx.ink's front buffer fails past
                        // 65536px in a dimension — a whole scrolling column of pages can exceed that at
                        // high zoom). Positioned at the current scroll offset, same as `ReadyScore`'s own
                        // wet window; `wetWorldToScreen` folds the SAME offset into its translate so
                        // document (Column-local) coordinates land exactly where the dry layer paints them.
                        wetWorldToScreen = remember(zoom, vScroll.value, vPadPx) {
                            Matrix().apply {
                                setScale(zoom, zoom)
                                postTranslate(0f, vPadPx - vScroll.value.toFloat())
                            }
                        },
                        wetModifier = Modifier
                            .fillMaxWidth()
                            .height(with(density) { viewportSize.height.coerceAtLeast(0).toDp() })
                            .offset { IntOffset(0, vScroll.value) },
                    )
                }
            }
        }
    }
}

/**
 * One page slot: a plain page-colored rectangle sized from [widthDp]/[heightDp] — computed by the caller
 * from the PDF's own point size (see [PdfVerticalLayout.pageHeightsPx]), NOT the bitmap — so the layout
 * never jumps when a bitmap arrives or a page falls out of the render window. Draws [PdfPageSource.bitmap]
 * over that rectangle once [isNearCurrentPage] and a render succeeds; never a per-page spinner while
 * waiting. [widthDp]/[heightDp]/[rasterWidthPx] are all derived from the settled `rasterScale`, so they —
 * and every other argument here — are unchanged across an entire pinch gesture, which is what lets a call
 * to this composable be skipped mid-gesture instead of relaying out on every frame.
 *
 * [bitmap] is held as this composable's OWN local state, separate from [PdfPageSource]'s internal cache,
 * so it must be dropped the moment [isNearCurrentPage] goes false — the caller's page `Column` is a plain
 * (non-lazy) one, so every page's item stays composed for the life of the surface, and a bitmap [source]
 * has already evicted (via `setWindow`, driven from the parent) would otherwise sit here forever, defeating
 * the whole point of windowing. See [PdfPageSource.bitmap]'s ownership contract: a bitmap already handed to
 * a caller is never force-recycled, so it is safe to keep drawing it right up until the moment this effect
 * nulls it out — the moment `isNearCurrentPage` flips is exactly a window move, i.e. NOT something to
 * retain across.
 */
@Composable
private fun PdfPageItem(
    index: Int,
    widthDp: Dp,
    heightDp: Dp,
    source: PdfPageSource,
    rasterWidthPx: Int,
    isNearCurrentPage: Boolean,
) {
    var bitmap by remember { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(index, rasterWidthPx, isNearCurrentPage) {
        // Outside the window, or the viewport isn't measured yet (`rasterWidthPx <= 0`, see the
        // caller): drop our own reference rather than requesting — or holding onto — a bitmap the
        // source itself no longer caches. See the class doc for why dropping matters here specifically.
        if (!isNearCurrentPage || rasterWidthPx <= 0) {
            bitmap = null
            return@LaunchedEffect
        }
        bitmap = source.bitmap(index, rasterWidthPx)
    }
    Box(Modifier.size(widthDp, heightDp).background(Color.White)) {
        // `Fit`, not `FillBounds`: the box is already sized to the page's own aspect ratio (see
        // `PdfVerticalLayout.pageHeightsPx`), so the two are visually equivalent here — `Fit` is the
        // ordinary default, `FillBounds` would only matter if the aspect ratios could mismatch. Either
        // way this is a plain draw-time scale of an already-rasterized bitmap, never a re-rasterization —
        // the caller's `graphicsLayer` on the page `Column` covers any LIVE pinch delta on top of this.
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

/**
 * New scroll offset (px) that keeps the content point under the pinch centroid fixed across a zoom step
 * of ratio `r = newScale / oldScale`. Identical formula to `ReaderScreen.kt`'s private
 * `focalAdjustedOffset` (duplicated rather than shared — `PagedScore` follows the same local-copy
 * convention rather than reaching into `ReadyScore`'s file-private helper). [pad] is a constant leading
 * offset (here, the fixed top padding, which does not itself scale with zoom) held out of the scaling.
 */
private fun focalAdjustedOffset(
    currentScroll: Float,
    centroid: Float,
    ratio: Float,
    pad: Float = 0f,
): Float = pad + ratio * (currentScroll - pad + centroid) - centroid
