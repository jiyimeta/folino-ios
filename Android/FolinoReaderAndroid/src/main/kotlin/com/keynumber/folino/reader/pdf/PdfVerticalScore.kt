package com.keynumber.folino.reader.pdf

import android.graphics.Bitmap
import android.graphics.Matrix
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.reader.DrawingAnchorWire
import com.keynumber.folino.reader.DrawingAnchorWireCodec
import com.keynumber.folino.reader.ON_SCREEN_CURSOR_ALPHA
import com.keynumber.folino.reader.PageFrameWire
import com.keynumber.folino.reader.PageFramesWire
import com.keynumber.folino.reader.PageFramesWireCodec
import com.keynumber.folino.reader.ReaderAnnotationJNI
import com.keynumber.folino.reader.ReaderAudioViewModel
import com.keynumber.folino.reader.ReaderState
import com.keynumber.folino.reader.ReaderViewModel
import com.keynumber.folino.reader.ViewportGeometry
import com.keynumber.folino.reader.ViewportUnderfill
import com.keynumber.folino.reader.axisContentPx
import com.keynumber.folino.reader.ink.AnnotationLayers
import com.keynumber.folino.reader.ink.AnnotationSurfaceState
import com.keynumber.folino.reader.ink.EraseGestureController
import com.keynumber.folino.reader.ink.PdfAnnotationCaptureController
import com.keynumber.folino.reader.ink.encodeWireArray
import com.keynumber.folino.reader.readerViewportGestures
import com.keynumber.folino.reader.rememberReaderViewportState
import com.keynumber.folino.reader.shouldAutoFollow
import com.keynumber.folino.reader.swiftjava.FolinoReaderJNI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
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
     * anything walking page boundaries in the OUTER, live-sized coordinate space must use THIS value in
     * place of the raw [gapPx], or the two drift apart by exactly `(scale/rasterScale - 1) * gapPx` per
     * gap during a pinch (self-corrects once `rasterScale` catches up to `scale` at gesture end).
     * Top/bottom padding does NOT need this correction: it sits OUTSIDE the layer, which is precisely why
     * `ViewportGeometry` carries it as a fixed, unscaled pad instead. [unitContentHeightPx] is where the
     * same correction is applied for the pannable extent.
     */
    fun liveGapPx(gapPx: Float, scale: Float, rasterScale: Float): Float = gapPx * (scale / rasterScale)

    /**
     * The scale-1 ("unit") vertical content extent, i.e. the SCALING half of [ViewportGeometry]'s
     * scaling / non-scaling split — the other half being this surface's fixed top/bottom padding, which
     * the caller passes as `fixedPadYPx`. `axisContentPx(unit, fixedPad, scale)` then reproduces the
     * surface's real content height at ANY scale, including one the layout has not run at yet, which is
     * exactly what [ReaderViewportState]'s pinch clamp needs.
     *
     * Each page's own height scales with the zoom, so those contribute their scale-1 height directly (a
     * page is [viewportWidthPx] wide at scale 1, its height following its own aspect ratio — the same
     * arithmetic as [pageHeightsPx]). The inter-page gaps do NOT: `Arrangement.spacedBy(PAGE_GAP)` is a
     * fixed dp measured INSIDE the page `Column`'s `graphicsLayer`, so on screen it is [gapPx] *
     * `scale / rasterScale` (see [liveGapPx]). Dividing it by [rasterScale] here turns it into a term
     * that scales cleanly with `scale`, which is what keeps the formula exact rather than merely correct
     * at rest. [rasterScale] is constant for the whole of a gesture — it only settles when the fingers
     * lift — so this never has to be re-derived mid-pinch.
     *
     * Returns the pages' own extent alone for a non-positive [rasterScale] (unreachable — the viewport
     * clamps its scales to `MIN_READER_SCALE`, which is 1 — but the division has to be total).
     */
    fun unitContentHeightPx(
        viewportWidthPx: Int,
        widthsPt: List<Double>,
        heightsPt: List<Double>,
        gapPx: Float,
        rasterScale: Float,
    ): Float {
        if (widthsPt.isEmpty()) return 0f
        var sum = 0f
        for (i in widthsPt.indices) {
            sum += (viewportWidthPx.toDouble() * heightsPt[i] / widthsPt[i]).toFloat()
        }
        if (rasterScale <= 0f) return sum
        return sum + gapPx * (widthsPt.size - 1) / rasterScale
    }

    /**
     * The page whose band contains the viewport's vertical CENTER, given the current scroll offset
     * ([scrollPx]) and [viewportHeightPx]. This is what drives [PdfPageSource.setWindow] — deliberately
     * scroll-position-based rather than pinch-scale-based, so a pinch alone (no scroll) never moves the
     * window. Clamped to the document; returns 0 for an empty document (real call sites never render
     * with `pageCount == 0`, but the function stays total rather than partial). [gapPx] must be
     * [liveGapPx]'s result when [pageHeightsPx] is live-scale-based, so this walks the SAME page
     * boundaries the pannable extent was declared with.
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
     * [gapPx] this layout already threads through [currentPageIndex] — the
     * page-anchored annotation pipeline needs each page's own frame to project stored ink back onto the
     * page it currently occupies (the raster page-frame list `PdfVerticalScore` feeds
     * `ReaderAnnotationJNI.pdfDisplayTransforms`). Which page a NEW stroke's centroid belongs to is NOT
     * decided here — that decision (and its inter-page-gap fallback) lives in shared Swift
     * (`PageAnchoringCore.pageIndex(forCentroid:pageFrames:)`, reached via
     * `nativePdfAnnotationCaptureResolvingPage`) so Kotlin carries none of that geometry itself.
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

    /** 72 points == 1 inch == 25.4mm. */
    private const val POINTS_TO_MM = 25.4 / 72.0

    /**
     * Raster px per document millimetre for a page whose own width is [pageWidthPt] points, rendered
     * [rasterWidthPx] px wide. This surface's annotation "world" space is raster px, NOT mm (`pxPerMM = 1f`
     * — see this file's class doc), but the toolbar's brush/eraser size preference is a physical-mm value
     * shared with the musical surfaces (`AnnotationSurfaceState.brushWidthWorld`/`eraserWidthWorld` — see
     * that type's own doc). This is the conversion factor a caller multiplies that mm preference by to get
     * the correct on-screen px thickness for a page of this width. Returns `1f` (identity — inert, not
     * "correct") for a non-positive [pageWidthPt]; real call sites already gate page geometry elsewhere.
     */
    fun pxPerPageMm(rasterWidthPx: Int, pageWidthPt: Double): Float {
        val pageWidthMm = pageWidthPt * POINTS_TO_MM
        if (pageWidthMm <= 0.0) return 1f
        return (rasterWidthPx / pageWidthMm).toFloat()
    }
}

/**
 * The vertical-continuous PDF reading surface: every page of [state], one below the other, panned as one
 * column. Modeled on [ReadyScore]'s viewport and zoom architecture (`ReaderScreen.kt`) — read that first —
 * because both are load-bearing here too.
 *
 * The viewport is [ReaderViewportState], the SAME free two-dimensional camera the musical surfaces use, not
 * a pair of Compose scroll containers: diagonal panning, a pinch that pans at the same time and keeps the
 * point under the centroid fixed, and momentum when the fingers lift. The offsets it publishes keep
 * `ScrollState`'s own sign convention (positive = scrolled down / right), so every consumer downstream —
 * tap-to-seek, the shared keep-in-view follow math over JNI, the ink overlays — reads exactly what it read
 * when this surface still scrolled. Panning is a layer translation on the content Box below rather than a
 * scroll container's placement.
 *
 * The two-stage zoom is reproduced the same way [ReadyScore] does it: [ReaderViewportState.scale] is where
 * the fingers are RIGHT NOW, [ReaderViewportState.rasterScale] is the zoom [source] last rendered bitmaps
 * at (`deferRaster = true`, so it only settles when the fingers lift), and the two are bridged by a
 * `remember`ed `graphicsLayer` whose `scaleX`/`scaleY` read them INSIDE the layer block — exactly
 * [ReadyScore]'s `scoreSurfaceModifier` shape, just wrapping this surface's page `Column` instead of a
 * `BandedScorePage`. That split is what keeps a pinch off the per-page-item recompute path: every page
 * `Box` is measured/positioned from the raster scale (stable for the whole gesture — see
 * `pageHeightsPxRaster` below), so [PdfPageItem] gets the SAME width/height arguments on every pinch frame,
 * and the layer transform alone covers the live zoom, exactly like the outer `contentWidthPx`/
 * `contentHeightPx` Box below tracks the live scale so the pannable extent stays correct while the inner
 * content stays put. Only the raster scale feeds [PdfVerticalLayout.renderWidthPx] for the actual
 * [PdfPageSource.bitmap] request width, and it only moves once, when a pinch gesture ends — never per
 * frame — so a pinch never touches [PdfPageSource] at all.
 *
 * Once the background OMR parse succeeds (`ReaderViewModel.pdfPlayback` reaches `Ready`), this surface draws the
 * playback cursor on the user's own pages and follows it, the same way [ReadyScore] does for a `.mscz` score. WHERE
 * the cursor sits on a page is decided entirely off this surface — swift-sheet-music's geometry side-car locates it,
 * and Folino's shared `PDFCursorProjection` (which iOS's PDF readers call directly) places it into whichever frame
 * the page currently occupies here; see [PdfCursorProjector]. This surface only supplies [pageFramesRaster] — the
 * SAME page geometry the annotation path already builds — and folds in its own live zoom when drawing. The follow
 * itself reuses the shared `nativeScrollOffsetPinningSystemTop` / `…KeepingInView` rules and the same
 * [shouldAutoFollow] gate + sticky manual-gesture suspension [ReadyScore] uses; only the world→scroll-space bridge
 * ([PdfCursorFollow]) is this surface's own, because its layout is.
 *
 * The projected cursor is deliberately read ONLY inside the leaf `Canvas`'s draw lambda (and inside the follow
 * effect's `collectLatest`) — never in this composable's body. `currentCursor` emits ~30x/second during playback, and
 * a body-level read would recompose every page slot and every gesture modifier on every tick.
 *
 * Tapping the PDF seeks there, the same as tapping a `.mscz` score: this surface only inverts its OWN camera (see
 * [PdfCursorFollow.worldPointForTap]) and the rest — which page, where on that page, and what is at that spot — is
 * decided natively by the exact inverse of the cursor's own projection plus swift-sheet-music's PDF hit-test (see
 * [PdfCursorProjector.cursorForTap]). A tap that hits nothing playable does nothing.
 *
 * [annotation] anchors ink to a PAGE, not a musical position: page index plus geometry
 * normalized to a fraction of that page's own width, so the same stroke re-renders correctly at any zoom
 * (the zoom factor cancels — see `ReaderAnnotationCore.PageAnchoringCore`, the shared Swift this and iOS's
 * PDF surfaces both call through). The dry/wet overlays mount OUTSIDE the page `Column`'s own
 * `graphicsLayer` (mirroring [ReadyScore]'s own ink overlays, never the score's live-record path) and use
 * their OWN camera: `pxPerMM = 1f` (raster page frames are already in px, no mm conversion) and
 * `scale = zoom` (the SAME live/raster ratio the Column's `graphicsLayer` reads), so
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
    /** User opt-out for continuous-playback auto-scroll (SettingsPrefs `autoFollow` / the display inspector row).
     * See [shouldAutoFollow]. Off ⇒ no re-pin during playback and no recenter on pause; the cursor still draws. */
    autoFollowEnabled: Boolean = true,
) {
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    // `deferRaster = true`: the pages are BITMAPS, so following the live pinch scale would re-request a
    // render from `PdfPageSource` on every frame of a gesture. The column stays rasterized (and laid out)
    // at `rasterScale`, a layer transform covers the difference while the fingers are down, and the one
    // real re-raster happens when they lift. `START` on both axes: the column is top-left anchored.
    val viewport = rememberReaderViewportState(
        deferRaster = true,
        underfillX = ViewportUnderfill.START,
        underfillY = ViewportUnderfill.START,
    )
    // Read directly (a fresh value on every pinch frame) for the same reason `ReadyScore` does: that only
    // resizes ONE Box (the pannable-extent Box below), not the per-page items; see the class doc.
    val scale = viewport.scale
    val rasterScale = viewport.rasterScale

    val vPadPx = with(density) { TOP_BOTTOM_PAD.toPx() }
    val gapPx = with(density) { PAGE_GAP.toPx() }
    // Keep-in-view breathing room for the paused / manual-seek auto-follow branch — the same 24.dp `ReadyScore`
    // passes as `pad` to the shared `nativeScrollOffsetKeepingInView`.
    val followPadPx = with(density) { 24.dp.toPx() }
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

    // The scaling half of this surface's content extent — the pages themselves plus the gaps between them,
    // expressed at scale 1. `remember`ed rather than recomputed inline because it walks every page and this
    // body recomposes on every pinch frame, while none of its inputs move during a gesture (`rasterScale`
    // settles only at fingers-up). See `PdfVerticalLayout.unitContentHeightPx` for why the gap divides by it.
    val unitContentHeightPx = remember(state, viewportSize.width, gapPx, rasterScale) {
        PdfVerticalLayout.unitContentHeightPx(
            viewportWidthPx = viewportSize.width,
            widthsPt = state.pageWidthsPt,
            heightsPt = state.pageHeightsPt,
            gapPx = gapPx,
            rasterScale = rasterScale,
        )
    }
    // The non-scaling half: breathing room above and below the column, plus the extra run-out that lets the
    // last page clear a floating control. Named apart from the pads themselves because the viewport wants
    // exactly this sum.
    val fixedPadYPx = vPadPx * 2 + extraBottomPadPx

    // Republished whenever the layout inputs move — see [ReadyScore]'s identical `SideEffect`, including
    // why this is a `SideEffect` and not an inline assignment (it writes snapshot state whose only readers,
    // the gesture loop and the auto-follow effect, run after the composition commits). A page is exactly
    // the viewport's width at scale 1, so the horizontal axis has no fixed padding at all.
    SideEffect {
        viewport.geometry = ViewportGeometry(
            viewportWidthPx = viewportSize.width.toFloat(),
            viewportHeightPx = viewportSize.height.toFloat(),
            unitContentWidthPx = viewportSize.width.toFloat(),
            unitContentHeightPx = unitContentHeightPx,
            fixedPadYPx = fixedPadYPx,
            leadingPadYPx = vPadPx,
        )
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

    // Playback cursor. `pdfPlayback` changes at most twice for a document (Parsing → Ready/Unavailable), so reading
    // it in this body costs nothing — unlike the CURSOR itself, which is deliberately kept out of the body (see the
    // class doc) and only ever read from the leaf `Canvas` below and the follow effect's own collector.
    val pdfPlayback by readerVm.pdfPlayback.collectAsStateWithLifecycle()
    val cursorProjector = rememberPdfCursorProjector(
        geometryHandle = (pdfPlayback as? PdfPlaybackState.Ready)?.handle?.geometryHandle,
        renderedPageWidthsPt = state.pageWidthsPt,
    )
    val cursorRect = rememberProjectedCursor(cursorProjector, audioVm.currentCursor, pageFramesRaster)

    // Auto-scroll: keep the playing cursor in view through the SHARED follow math (JNI) — pin the playing system to
    // the top while the lookahead anchor is set (playing), gentle keep-in-view when paused / on a manual seek.
    // Mirrors `ReadyScore`'s effect exactly, including the two-level gate (`autoFollowEnabled`, then the sticky
    // manual-viewport suspension for the PLAYING re-pin only). The live zoom is read from `viewport` INSIDE the
    // collector rather than being a key: a state read from a coroutine subscribes to nothing, so a pinch never
    // restarts this effect — the mistake `ReadyScore`'s own key list documents at length.
    //
    // Driven off `cursorRect` — the SAME projection the `Canvas` below draws — rather than re-resolving
    // `currentCursor` itself. Both wanted the identical rect for the identical tick against the identical page
    // frames, so projecting twice was two wasted native hops per tick (~30/s) on the main dispatcher. Reusing the
    // published `State` is reuse, not a second implementation: only the LOOKAHEAD anchor still needs its own
    // projection, because it is a different cursor and nothing else resolves it.
    LaunchedEffect(cursorProjector, pageFramesRaster, autoFollowEnabled, viewportSize) {
        val projector = cursorProjector ?: return@LaunchedEffect
        if (viewportSize.height <= 0 || viewportSize.width <= 0) return@LaunchedEffect
        if (!autoFollowEnabled) return@LaunchedEffect
        combine(snapshotFlow { cursorRect.value }, audioVm.scrollAnchorCursor) { rect, anchor -> rect to anchor }
            .collectLatest { (realRect, anchor) ->
                // Null covers both "no live cursor" and "the cursor can't be placed on this layout" — either way
                // there is nothing to bring into view.
                if (realRect == null) return@collectLatest
                val isPlaying = anchor != null
                if (isPlaying &&
                    !shouldAutoFollow(autoFollowEnabled, isPlaying, audioVm.isPlaybackFollowSuspended.value)
                ) {
                    return@collectLatest
                }
                val zoom = viewport.scale / viewport.rasterScale
                val span = PdfCursorFollow.verticalSpan(realRect.top, realRect.height, zoom, vPadPx)

                val newY = if (anchor != null) {
                    // Playing: pin the playing page-row to the top, triggered by the lookahead leaving the viewport.
                    // `topInset = vPadPx` clears the same fixed pad the content sits under.
                    val lookaheadMax = projector.project(anchor, pageFramesRaster)
                        ?.let { PdfCursorFollow.verticalSpan(it.top, it.height, zoom, vPadPx).max }
                        ?: span.max
                    FolinoReaderJNI.nativeScrollOffsetPinningSystemTop(
                        viewport.offsetY.toDouble(),
                        span.min.toDouble(),
                        span.max.toDouble(),
                        lookaheadMax.toDouble(),
                        viewportSize.height.toDouble(),
                        vPadPx.toDouble(),
                    ).toFloat()
                } else {
                    FolinoReaderJNI.nativeScrollOffsetKeepingInView(
                        viewport.offsetY.toDouble(),
                        span.min.toDouble(),
                        span.max.toDouble(),
                        viewportSize.height.toDouble(),
                        followPadPx.toDouble(),
                    ).toFloat()
                }
                if (abs(newY - viewport.offsetY) >= 0.5f) {
                    viewport.animateOffsetYTo(newY)
                }

                // Horizontal follow only while zoomed past fit-width — at fit the page is exactly the viewport's
                // width, so the clamp leaves no horizontal range at all. Matches `ReadyScore`.
                val liveWidth = PdfVerticalLayout.renderWidthPx(viewportSize.width, viewport.scale)
                if (liveWidth > viewportSize.width + 0.5f) {
                    val hSpan = PdfCursorFollow.horizontalSpan(realRect.left, realRect.width, zoom)
                    val newX = FolinoReaderJNI.nativeScrollOffsetKeepingInView(
                        viewport.offsetX.toDouble(),
                        hSpan.min.toDouble(),
                        hSpan.max.toDouble(),
                        viewportSize.width.toDouble(),
                        followPadPx.toDouble(),
                    ).toFloat()
                    if (abs(newX - viewport.offsetX) >= 0.5f) {
                        viewport.animateOffsetXTo(newX)
                    }
                }
            }
    }

    // The pannable extent, in the SAME `unit * scale + fixedPad` form the viewport clamps against, so the
    // sized Box below and `ReaderViewportState`'s own clamp can never disagree about where the end of the
    // document is. Recomputed directly from the live `scale` every pinch frame — the same trade-off
    // `ReadyScore`'s outer content Box makes — while the page items below stay sized from `rasterWidthPx`.
    val contentWidthPx = axisContentPx(viewportSize.width.toFloat(), fixedPadPx = 0f, scale = scale)
    val contentHeightPx = axisContentPx(unitContentHeightPx, fixedPadPx = fixedPadYPx, scale = scale)

    // Reused every re-derivation below instead of allocating a fresh `FloatArray` per scroll/pinch frame
    // — see `PdfVerticalLayout.pageHeightsPxInto`'s doc.
    val liveHeightsScratch = remember(state) { FloatArray(pageCount) }

    // `currentPage` must be read from `viewport.offsetY` (a per-pan-frame snapshot value) WITHOUT making
    // the whole surface recompose on every pan tick — wrapped in `derivedStateOf` so a reader (the
    // `LaunchedEffect` below, and `isNearCurrentPage` per item) only recomposes when the computed page
    // index actually changes. The live-`scale`-based geometry is recomputed INSIDE the lambda (not
    // captured from `contentHeightPx` above) so this stays correct across pinch frames without
    // re-deriving the state itself: `derivedStateOf`'s block reruns on every relevant snapshot read
    // (`viewport.offsetY`, `viewportSize`, `viewport.scale`, `viewport.rasterScale`), it just only
    // PUBLISHES a change when the resulting `Int` differs. This mirrors `ReadyScore`, which never reads
    // its own offsets directly in its body either — only inside gesture callbacks and effects. Uses the
    // `liveGapPx` correction so this walks the page boundaries that are actually on screen, which mid-pinch
    // are stretched by the live/raster ratio.
    val currentPage by remember(state, gapPx, vPadPx, viewport) {
        derivedStateOf {
            // NOT a pure function of its inputs: it mutates `liveHeightsScratch` (a `remember`ed, shared
            // buffer) as a side effect on every re-derivation. That is safe ONLY because `derivedStateOf`
            // blocks, like the rest of Compose's snapshot system, are read/run on the composition thread
            // (the main thread here) — there is no concurrent writer this could race with. If a future
            // change ever moved this computation off that thread (e.g. into a background-dispatched
            // effect), this mutation would need its own synchronization.
            val liveWidth = if (viewportSize.width > 0) {
                PdfVerticalLayout.renderWidthPx(viewportSize.width, viewport.scale)
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
                scrollPx = viewport.offsetY,
                viewportHeightPx = viewportSize.height.toFloat(),
                pageHeightsPx = liveHeightsScratch,
                gapPx = PdfVerticalLayout.liveGapPx(gapPx, viewport.scale, viewport.rasterScale),
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

    // Owns this surface's BEGIN/MOVE/END erase-drag state machine — its own instance, not shared with
    // ReaderScreen's musical one (an in-flight drag has no reason to survive a layout-mode switch; see
    // the class doc). `remember`ed so a drag survives a recomposition mid-gesture.
    val eraseController = remember { EraseGestureController() }

    // This surface's annotation "world" space is raster px (`pxPerMM = 1f` below — see the class doc), but
    // the toolbar's brush/eraser size is a physical-mm preference shared with the musical surfaces (whose
    // world space genuinely is mm). Multiplying by this converts that mm preference into the correct
    // on-screen px thickness for the CURRENT page. Recomputed only when the raster geometry or the current
    // page changes (a mixed-page-size document can have a different points-per-width per page), never on a
    // live pinch frame.
    val pxPerPageMm = remember(rasterWidthPx, state, currentPage) {
        val pageWidthPt = state.pageWidthsPt.getOrElse(currentPage) { state.pageWidthsPt.firstOrNull() ?: 1.0 }
        PdfVerticalLayout.pxPerPageMm(rasterWidthPx, pageWidthPt)
    }

    // A local copy of the shared `annotation` bundle with PDF-specific `onStrokeCaptured`/`onEraseGesture`:
    // the shared ones (built once in `ReaderScreen`) resolve a musical anchor via `scoreHandle`, which is
    // always null for a PDF (no parsed score is produced for one yet). Every other field is
    // forwarded unchanged EXCEPT `brushWidthWorld`/`eraserWidthWorld`, which get converted from the shared
    // bundle's mm value into THIS surface's px world space (see `pxPerPageMm`'s doc — this is also why the
    // fields aren't named `widthMm`/`eraserWidthMm`: on this surface they hold px, not mm). Rebuilt fresh
    // every recomposition (no `remember`): the base `annotation` itself is a fresh object every
    // `ReaderScreen` recomposition already (see its own construction site), so memoizing here would buy
    // nothing, and neither closure is ever used as a `LaunchedEffect` key — only invoked from a gesture
    // callback — so a fresh instance every time is fine, exactly how `AnnotationWetOverlay` already expects
    // it (`rememberUpdatedState` there covers freshness).
    val pdfAnnotation = annotation?.let { base ->
        val brushWidthWorld = base.brushWidthWorld * pxPerPageMm
        val eraserWidthWorld = base.eraserWidthWorld * pxPerPageMm
        AnnotationSurfaceState(
            annotationMode = base.annotationMode,
            drawings = base.drawings,
            layoutGeneration = base.layoutGeneration,
            colorRGBA = base.colorRGBA,
            brushWidthWorld = brushWidthWorld,
            eraserMode = base.eraserMode,
            eraserWidthWorld = eraserWidthWorld,
            onEraseGesture = { phase, pathWorld ->
                // Presets are DIAMETERS; `applyErase` (via `EraseGestureController`) wants a radius —
                // already in raster px, per `eraserWidthWorld`'s own conversion above.
                val radiusWorld = eraserWidthWorld / 2f
                eraseController.handle(
                    scope = scope,
                    phase = phase,
                    pathWorld = pathWorld,
                    radiusWorld = radiusWorld,
                    // Always "ready": a PDF page-anchor erase needs no ssm score to arm (unlike the
                    // musical surfaces' own gate — see `ReaderScreen`'s call site).
                    ready = true,
                    // No ssm score for a PDF — `reanchor`'s musical recapture branch never runs; a page
                    // fragment's Phase 1 slice is already correctly re-anchored (see that function's doc).
                    scoreHandle = null,
                    currentDrawings = readerVm::currentDrawings,
                    // The SAME resolver the dry overlay uses (built once above, keyed on the raster page
                    // geometry) — not a second implementation of "how to get display transforms for this
                    // layer."
                    resolveDisplayTransforms = resolveDisplayTransforms,
                    releaseWetRetention = base.inkHandoff::releaseAll,
                    onInProgress = readerVm::eraseInProgress,
                    onCommitted = readerVm::eraseCommitted,
                )
            },
            inkHandoff = base.inkHandoff,
            onStrokeCaptured = { stroke, onCommitted ->
                val capturedColorRGBA = base.colorRGBA
                val capturedWidthWorld = brushWidthWorld
                val frames = pageFramesRaster
                scope.launch(Dispatchers.Default) {
                    // Page resolution (centroid → page, including the inter-page-gap fallback) happens
                    // entirely in shared Swift via `PageAnchoringCore.capture(strokes:pageFrames:)` — no
                    // Kotlin reimplementation of that geometry (see `PdfVerticalLayout.pageOriginsPx`'s doc).
                    val drawing = PdfAnnotationCaptureController.captureResolvingPage(
                        stroke = stroke,
                        tool = AnnotationSurfaceState.WET_STROKE_TOOL,
                        colorRGBA = capturedColorRGBA,
                        baseWidthSp = capturedWidthWorld,
                        pageFrames = frames,
                    )
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
            // Tap-to-seek on the PDF itself. Its own `pointerInput` so it coexists with the viewport gestures below,
            // exactly as `ReadyScore`'s does: `detectTapGestures` only fires on a down+up with no drag, while the
            // viewport loop consumes moves past touch slop — neither steals the other's events.
            //
            // The tap arrives in this outer (viewport) px space; `worldPointForTap` undoes this surface's own camera
            // (both offsets, the fixed top pad, the live/raster zoom) to reach the raster-px world space
            // `pageFramesRaster` is expressed in, and everything past that point — which page, where on it, and what
            // is there — is decided natively (see `PdfCursorProjector.cursorForTap`). A tap that resolves to nothing
            // does nothing at all: no toast, no flash.
            //
            // `handleTap` is the same entry point the musical surfaces seek through, so a seek here also RESUMES
            // playback follow (an explicit target is exactly the signal that clears a manual-viewport suspension).
            // Disabled while annotating: there, a single-finger tap belongs to the wet overlay.
            .pointerInput(cursorProjector, pageFramesRaster, annotationMode, audioVm) {
                if (annotationMode) return@pointerInput
                val projector = cursorProjector ?: return@pointerInput
                detectTapGestures { offset ->
                    // Read through `viewport`, never a value captured from the composition: a `pointerInput`
                    // handler only restarts when a KEY changes, and a pan changes none of them, so a captured
                    // offset would go stale the moment the reader pans and seek to the wrong note.
                    val world = PdfCursorFollow.worldPointForTap(
                        tap = offset,
                        hScrollPx = viewport.offsetX,
                        vScrollPx = viewport.offsetY,
                        // A gesture callback is not composition, so reading the live scale here is safe.
                        zoom = viewport.scale / viewport.rasterScale,
                        topPadPx = vPadPx,
                    ) ?: return@detectTapGestures
                    val cursor = projector.cursorForTap(world, pageFramesRaster) ?: return@detectTapGestures
                    audioVm.handleTap(cursor)
                }
            }
            // Pan, pinch, and fling — one loop, the SAME one the musical surfaces use. While annotating only
            // two-finger gestures are taken (a single finger is a stroke) and momentum is off, so the column does
            // not coast away from where the reader is writing. The one re-raster point for a whole gesture is
            // `settleRaster`, which the loop fires when the last finger lifts.
            .readerViewportGestures(
                state = viewport,
                scope = scope,
                key = viewportSize.width,
                enabled = viewportKnown,
                // `annotationMode` is a plain composition value, not observable state, so this lambda is only
                // correct because `allowFling` below carries the same value INTO the `pointerInput` key list —
                // see [ReadyScore]'s identical comment for the full rationale.
                allowSingleFingerPan = { !annotationMode },
                allowFling = !annotationMode,
                onManualViewportChange = audioVm::suspendPlaybackFollowForManualViewportChange,
            ),
        contentAlignment = Alignment.TopStart,
    ) {
        // Panning is a layer translation now, not a scroll container's placement. The clip and the
        // `graphicsLayer` MUST stay on this one node — see [ReadyScore]'s identical comment for why.
        //
        // Measure the content UNBOUNDED and report the viewport's size upward. `verticalScroll` did exactly
        // this (an infinite max on its axis) and it was the only thing letting the content box be taller
        // than the screen: `Modifier.size` enforces the constraints it is handed, so under the viewport's
        // bounded constraints a document-tall box is silently coerced to a screenful, taking every page,
        // every `fillMaxSize` overlay, and the document-sized ink `AndroidView` down with it.
        Box(
            Modifier
                .clipToBounds()
                .graphicsLayer {
                    translationX = -viewport.offsetX
                    translationY = -viewport.offsetY
                }
                .layout { measurable, constraints ->
                    val placeable = measurable.measure(Constraints())
                    layout(constraints.maxWidth, constraints.maxHeight) { placeable.place(0, 0) }
                },
        ) {
            // Sized from the LIVE `scale` — this is the pannable extent, so it must track the pinch every
            // frame for the clamp and what's on screen to agree. Its child below is sized at `rasterScale`
            // instead and bridged by a layer transform, exactly like `ReadyScore`'s outer content Box vs.
            // its `scoreSurfaceModifier`.
            Box(
                Modifier.size(
                    width = with(density) { contentWidthPx.toDp() },
                    height = with(density) { contentHeightPx.toDp() },
                ),
            ) {
                // Remembered so the viewport's two scales are read INSIDE the `graphicsLayer` block
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
                val columnModifier = remember(vPadPx, density, viewport) {
                    Modifier
                        .wrapContentSize(align = Alignment.TopStart, unbounded = true)
                        .padding(top = with(density) { vPadPx.toDp() })
                        .graphicsLayer {
                            val zoom = viewport.scale / viewport.rasterScale
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
                                // Per PAGE, not per document: the cap bounds the larger dimension, and a
                                // landscape page in an otherwise-portrait score reaches it at a different
                                // zoom than its neighbors do.
                                bitmapWidthPx = PdfRasterBudget.rasterWidthPx(
                                    rasterWidthPx,
                                    state.pageWidthsPt[i],
                                    state.pageHeightsPt[i],
                                ),
                                isNearCurrentPage = abs(i - currentPage) <= PDF_WINDOW_RADIUS,
                            )
                        }
                    }
                }

                // Playback cursor, over the pages and UNDER the ink (a stroke the reader drew on a note should stay
                // on top of the bar sweeping past it). Same padding as the dry ink layer, so world y = 0 lands at
                // this Canvas's y = 0; the live/raster zoom is folded in by the draw transform instead of the
                // Column's own `graphicsLayer`, which this Canvas is a sibling of, not a child.
                //
                // Every state this reads — the cursor rect and both scales — is read INSIDE the draw lambda, so a
                // cursor tick (or a pinch frame) invalidates the draw phase alone and never recomposes the surface.
                // Same discipline as `columnModifier`'s `graphicsLayer` block above.
                val cursorColor = MaterialTheme.colorScheme.primary.copy(alpha = ON_SCREEN_CURSOR_ALPHA)
                Canvas(
                    Modifier
                        .fillMaxSize()
                        .padding(top = with(density) { vPadPx.toDp() }),
                ) {
                    val rect = cursorRect.value ?: return@Canvas
                    val zoom = viewport.scale / viewport.rasterScale
                    withTransform({ scale(zoom, zoom, pivot = Offset.Zero) }) {
                        drawRect(
                            color = cursorColor,
                            topLeft = Offset(rect.left, rect.top),
                            size = Size(rect.width, rect.height),
                        )
                    }
                }

                pdfAnnotation?.let { an ->
                    // Own camera, OUTSIDE the Column's `graphicsLayer` — never wrap the wet (androidx.ink)
                    // overlay in a Compose transform (see the class doc and `AnnotationLayers`' own front-
                    // buffer note); `zoom` matches the Column's own live/raster ratio so both track the
                    // same visual zoom without the ink path ever re-deriving page geometry mid-pinch.
                    val zoom = viewport.scale / viewport.rasterScale
                    // See the `wetWorldToScreen`/`wetModifier` comment below for why this read is gated.
                    val wetWindowTopPx = if (an.annotationMode) viewport.offsetY.roundToInt() else 0
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
                        // high zoom). Positioned at the current vertical offset, same as `ReadyScore`'s own
                        // wet window; `wetWorldToScreen` folds the SAME offset into its translate so
                        // document (Column-local) coordinates land exactly where the dry layer paints them.
                        // No horizontal counterpart is needed: the window is `fillMaxWidth` of a content Box
                        // that is already the full zoomed width, so a horizontal pan moves it via the
                        // ancestor pan layer with nothing left to compensate.
                        //
                        // This offset CAN move mid-annotation: a two-finger pan is allowed while the pen is
                        // out. That is sound because the two are mutually exclusive in time — the wet layer
                        // cancels its stroke when a second finger lands — and it is the same trade
                        // `ReadyScore` already makes.
                        //
                        // `viewport.offsetY` is read ONLY inside the `annotationMode` branch: reading it
                        // UNCONDITIONALLY here would subscribe this composable's whole body to every pan
                        // tick even with annotation OFF — the `wetWorldToScreen`/`wetModifier` this feeds
                        // aren't even mounted then (`AnnotationLayers` only mounts the wet overlay under
                        // `annotation.annotationMode`), so `0` is an inert placeholder for that case. A read
                        // inside a branch that isn't taken doesn't register with the snapshot system.
                        wetWorldToScreen = remember(zoom, wetWindowTopPx, vPadPx) {
                            Matrix().apply {
                                setScale(zoom, zoom)
                                postTranslate(0f, vPadPx - wetWindowTopPx.toFloat())
                            }
                        },
                        wetModifier = Modifier
                            .fillMaxWidth()
                            .height(with(density) { viewportSize.height.coerceAtLeast(0).toDp() })
                            .offset { IntOffset(0, wetWindowTopPx) },
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
 * waiting. [widthDp]/[heightDp]/[bitmapWidthPx] are all derived from the settled `rasterScale`, so they —
 * and every other argument here — are unchanged across an entire pinch gesture, which is what lets a call
 * to this composable be skipped mid-gesture instead of relaying out on every frame.
 *
 * [bitmapWidthPx] is the raster width AFTER [PdfRasterBudget], so it may be smaller than the [widthDp] the
 * box is laid out at; the `ContentScale.Fit` draw below upscales the difference. That is deliberate — see
 * [PdfRasterBudget]'s doc.
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
    bitmapWidthPx: Int,
    isNearCurrentPage: Boolean,
) {
    var bitmap by remember { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(index, bitmapWidthPx, isNearCurrentPage) {
        // Outside the window, or the viewport isn't measured yet (`bitmapWidthPx <= 0`, which
        // `PdfRasterBudget` passes through unchanged — see the caller): drop our own reference rather than
        // requesting — or holding onto — a bitmap the source itself no longer caches. See the class doc
        // for why dropping matters here specifically.
        if (!isNearCurrentPage || bitmapWidthPx <= 0) {
            bitmap = null
            return@LaunchedEffect
        }
        bitmap = source.bitmap(index, bitmapWidthPx)
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
