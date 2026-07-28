package com.keynumber.folino.reader.pdf

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import com.keynumber.folino.reader.PageFrameWire
import com.keynumber.folino.reader.PageFrameWireCodec
import com.keynumber.folino.reader.ReaderDiagnostics
import com.keynumber.folino.reader.swiftjava.Data as SwiftData
import com.keynumber.folino.reader.swiftjava.FolinoReaderJNI as SwiftJavaJNI
import io.github.jiyimeta.sheetmusic.PdfPageSizesWireCodec
import io.github.jiyimeta.sheetmusic.PdfRectWire
import io.github.jiyimeta.sheetmusic.PdfRectWireCodec
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import org.swift.swiftkit.core.SwiftMemoryManagement
import kotlin.math.abs

/**
 * The playback cursor placed on a PDF surface: the page it belongs to plus its rectangle in that surface's own
 * "world" space — RASTER PIXELS on both PDF surfaces (`pxPerMM = 1f`), not millimetres. The caller folds in its own
 * live zoom / pan camera when drawing, exactly as it already does for the annotation dry overlay.
 */
internal data class PdfCursorWorldRect(
    val pageIndex: Int,
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
) {
    val bottom: Float get() = top + height
    val right: Float get() = left + width
}

/**
 * Resolves a [ScoreCursor] to a rectangle on the displayed PDF. Two native hops, no arithmetic on this side:
 * swift-sheet-music's geometry side-car says WHERE on the original page the cursor sits (`nativePdfCursorRect`, in
 * that page's own top-left point space), and Folino's shared `PDFCursorProjection` — the same code iOS's PDF readers
 * call directly — places that rect into the frame the page currently occupies on this surface
 * (`nativePdfCursorDisplayRect`).
 *
 * Built by [rememberPdfCursorProjector], which also performs the once-per-document check that the two sides agree
 * about how wide the pages are.
 */
internal class PdfCursorProjector(
    private val geometryHandle: Long,
    /** Side-car mediaBox widths (PDF points) indexed by page; `0.0` = "this page's size was never recorded". */
    private val geometryPageWidthsPt: DoubleArray,
) {
    /**
     * Which page [cursor] falls on, or `null` when the side-car can't locate it (a stale cursor against a different
     * score). Cheaper than [project] — the auto-page-turn only needs the index, never the rectangle.
     */
    fun pageIndex(cursor: ScoreCursor): Int? = cursorRect(cursor)?.pageIndex

    /**
     * [cursor]'s rectangle in the surface's world space, given the frames its pages currently occupy there
     * (positionally indexed by page — the SAME list the annotation path feeds
     * `ReaderAnnotationJNI.pdfDisplayTransforms`). `null` when there is nothing to draw: the side-car can't locate
     * the cursor, its page isn't in [pageFrames], the side-car never recorded that page's width, or the page has no
     * frame this layout (paged mode's zero-width placeholder for every off-screen page).
     */
    fun project(cursor: ScoreCursor, pageFrames: List<PageFrameWire>): PdfCursorWorldRect? {
        val rect = cursorRect(cursor) ?: return null
        val frame = pageFrames.getOrNull(rect.pageIndex) ?: return null
        val widthPt = geometryPageWidthsPt.getOrElse(rect.pageIndex) { 0.0 }
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        val placedBytes = SwiftJavaJNI.nativePdfCursorDisplayRect(
            rect.x,
            rect.y,
            rect.width,
            rect.height,
            widthPt,
            SwiftData.fromByteArray(PageFrameWireCodec.encode(frame), arena),
            arena,
        ).toByteArray()
        if (placedBytes.isEmpty()) return null
        val placed = try {
            PageFrameWireCodec.decode(placedBytes)
        } catch (e: Exception) {
            // Wire skew between this Kotlin codec and the .so that produced the bytes. Drawing nothing for a frame
            // is the right degradation; reporting it is how a stale .so surfaces instead of reading as "no cursor".
            ReaderDiagnostics.recordNonFatal(e)
            return null
        }
        return PdfCursorWorldRect(
            pageIndex = rect.pageIndex,
            left = placed.x.toFloat(),
            top = placed.y.toFloat(),
            width = placed.width.toFloat(),
            height = placed.height.toFloat(),
        )
    }

    private fun cursorRect(cursor: ScoreCursor): PdfRectWire? {
        val bytes = SheetMusicJNI.nativePdfCursorRect(geometryHandle, ScoreCursorCodec.encode(cursor))
        if (bytes.isEmpty()) return null
        return try {
            PdfRectWireCodec.decode(bytes)
        } catch (e: Exception) {
            ReaderDiagnostics.recordNonFatal(e)
            null
        }
    }
}

/**
 * A [PdfCursorProjector] for [geometryHandle] (the `PdfScoreHandle.geometryHandle` a successful background parse
 * published), or `null` while the PDF isn't playable — the surfaces draw no cursor and run no auto-follow then.
 *
 * Also runs the one-per-document sanity check the cursor's correctness rests on: the side-car's page widths and
 * `PdfRenderer`'s ([renderedPageWidthsPt], the same values `ReaderState.ReadyPdf` lays the pages out from) are both
 * PDF points read from the same file, so they must agree. A disagreement means every cursor on that page is about to
 * be scaled by the wrong factor — reported once as a non-fatal, then drawn anyway, because a cursor a few percent off
 * is more useful than a cursor that silently never appears. The tolerance itself lives in shared Swift
 * (`PDFCursorProjection.pageWidthsAgree`), reached through `nativePdfPageWidthsAgree`.
 */
@Composable
internal fun rememberPdfCursorProjector(
    geometryHandle: Long?,
    renderedPageWidthsPt: List<Double>,
): PdfCursorProjector? = remember(geometryHandle, renderedPageWidthsPt) {
    if (geometryHandle == null) return@remember null
    val sizesBytes = SheetMusicJNI.nativePdfPageSizes(geometryHandle)
    if (sizesBytes.isEmpty()) return@remember null
    val sizes = try {
        PdfPageSizesWireCodec.decode(sizesBytes)
    } catch (e: Exception) {
        ReaderDiagnostics.recordNonFatal(e)
        return@remember null
    }
    // A trailing run of pages the importer never recorded is simply not appended, so this array is padded out to the
    // document's real page count with the side-car's own "unknown" encoding (0.0) rather than being indexed short.
    val widths = DoubleArray(renderedPageWidthsPt.size) { sizes.widths.getOrElse(it) { 0.0 } }
    reportPageWidthDisagreement(renderedPageWidthsPt, widths)
    PdfCursorProjector(geometryHandle, widths)
}

/**
 * Record ONE non-fatal for the whole document if any page's rendered width disagrees with the side-car's, naming the
 * first offending page and how far apart the two are. One report, not one per page: a document whose boxes are read
 * differently disagrees on every page, and a per-page report would bury the signal.
 */
private fun reportPageWidthDisagreement(renderedPageWidthsPt: List<Double>, geometryPageWidthsPt: DoubleArray) {
    for (i in renderedPageWidthsPt.indices) {
        val rendered = renderedPageWidthsPt[i]
        val geometry = geometryPageWidthsPt.getOrElse(i) { 0.0 }
        if (SwiftJavaJNI.nativePdfPageWidthsAgree(rendered, geometry)) continue
        ReaderDiagnostics.recordNonFatal(
            IllegalStateException(
                "PDF page $i width disagrees between renderer and OMR geometry: " +
                    "rendered=${rendered}pt geometry=${geometry}pt delta=${abs(rendered - geometry)}pt — " +
                    "the playback cursor on this document is mis-scaled",
            ),
        )
        return
    }
}

/**
 * The current playback cursor, projected into the surface's world space and republished only when it MOVES.
 *
 * Returned as a [State] rather than a plain value on purpose: the caller must read `.value` in a LEAF — a `Canvas`
 * draw lambda, or inside a `collectLatest` — never in the surface's own composable body. `currentCursor` emits
 * ~30x/second during playback; a body-level read would recompose the entire surface (every page slot, every gesture
 * modifier) on every tick, which is the regression that already bit the iOS reader once.
 */
@Composable
internal fun rememberProjectedCursor(
    projector: PdfCursorProjector?,
    cursorFlow: StateFlow<ScoreCursor?>,
    pageFrames: List<PageFrameWire>,
): State<PdfCursorWorldRect?> {
    val rect = remember { mutableStateOf<PdfCursorWorldRect?>(null) }
    LaunchedEffect(projector, cursorFlow, pageFrames) {
        if (projector == null) {
            rect.value = null
            return@LaunchedEffect
        }
        cursorFlow.collectLatest { cursor ->
            rect.value = cursor?.let { projector.project(it, pageFrames) }
        }
    }
    return rect
}

/**
 * A target span (min..max) for one axis of a surface's scroll space — what the shared keep-in-view / pin-to-top
 * follow math (`FolinoReaderJNI.nativeScrollOffset*`) takes as `targetMin` / `targetMax`.
 */
internal data class PdfScrollSpan(val min: Float, val max: Float)

/**
 * Converts a [PdfCursorWorldRect] into the vertical PDF surface's SCROLL space.
 *
 * This is camera, not cursor geometry: where the cursor sits on the PDF is decided in shared Swift (see
 * [PdfCursorProjector]); how this particular surface's world maps onto its own scroll offsets is the surface's own
 * layout, which differs by platform by design (iOS's continuous PDF reader scrolls an unzoomed point-space stack;
 * this one scrolls a raster-pixel column under a `graphicsLayer`). Pulled out as pure `Float` arithmetic so the two
 * bridges between those spaces are unit-testable without a Compose environment.
 */
internal object PdfCursorFollow {
    /**
     * World y-span → scroll-space y-span. [zoom] is the live/raster ratio the page `Column`'s `graphicsLayer`
     * applies (so world pixels become on-screen pixels), and [topPadPx] is the fixed leading pad that sits OUTSIDE
     * that layer and therefore does NOT scale — the same asymmetry `PdfVerticalScore`'s own scroll-extent math and
     * `focalAdjustedOffset` already encode.
     */
    fun verticalSpan(worldTop: Float, worldHeight: Float, zoom: Float, topPadPx: Float): PdfScrollSpan =
        PdfScrollSpan(topPadPx + worldTop * zoom, topPadPx + (worldTop + worldHeight) * zoom)

    /**
     * World x-span → scroll-space x-span. No leading pad on this axis: the page `Column` starts flush at x = 0 (its
     * `wrapContentSize` aligns `TopStart` and the `graphicsLayer` pivots there), so the zoom alone maps the two.
     */
    fun horizontalSpan(worldLeft: Float, worldWidth: Float, zoom: Float): PdfScrollSpan =
        PdfScrollSpan(worldLeft * zoom, (worldLeft + worldWidth) * zoom)
}
