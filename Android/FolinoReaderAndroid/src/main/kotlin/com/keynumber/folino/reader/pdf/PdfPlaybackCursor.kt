package com.keynumber.folino.reader.pdf

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import com.keynumber.folino.reader.PageFrameWire
import com.keynumber.folino.reader.PageFrameWireCodec
import com.keynumber.folino.reader.PageFramesWire
import com.keynumber.folino.reader.PageFramesWireCodec
import com.keynumber.folino.reader.PdfPageHitWireCodec
import com.keynumber.folino.reader.PdfPageWidthsWire
import com.keynumber.folino.reader.PdfPageWidthsWireCodec
import com.keynumber.folino.reader.ReaderDiagnostics
import com.keynumber.folino.reader.swiftjava.Data as SwiftData
import com.keynumber.folino.reader.swiftjava.FolinoReaderJNI as SwiftJavaJNI
import io.github.jiyimeta.sheetmusic.PdfPageSizesWireCodec
import io.github.jiyimeta.sheetmusic.PdfRectWire
import io.github.jiyimeta.sheetmusic.PdfRectWireCodec
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.withContext
import org.swift.swiftkit.core.SwiftMemoryManagement
import java.util.concurrent.atomic.AtomicLong
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
        // A page that isn't laid out this frame — paged mode fills every off-screen page's slot with a zero-width
        // placeholder, and in that mode EVERY composed page but one is off-screen, so without this the common case
        // is a native round trip whose only outcome is a decline. A guard on an input that cannot produce a result,
        // not a second copy of the projection: the placement rule itself still lives entirely in shared Swift, and
        // `PDFCursorProjection.displayRect` keeps its own identical guard as the authority.
        if (frame.width <= 0.0) return null
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

    /**
     * The engine cursor under a tap, or `null` when the tap hit nothing playable — in which case the caller does
     * NOTHING (no seek, no toast, no flash). The mirror image of [project], and two native hops for the same reason:
     * Folino's shared `PDFCursorProjection` decides which page the tap landed on and where on that page it sits
     * (`nativePdfTapPageHit`, the exact inverse of the placement [project] uses), then swift-sheet-music's geometry
     * side-car says what is at that spot on the original page (`nativePdfHitTest`). No arithmetic on this side.
     *
     * [contentPoint] is in the surface's own WORLD space — raster pixels, the same space [pageFrames] is expressed
     * in (see [PdfCursorWorldRect]). Inverting the surface's own camera (screen → world) is the caller's job, since
     * that camera is the one thing that genuinely differs per surface.
     */
    fun cursorForTap(contentPoint: Offset, pageFrames: List<PageFrameWire>): ScoreCursor? {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        val hitBytes = SwiftJavaJNI.nativePdfTapPageHit(
            contentPoint.x.toDouble(),
            contentPoint.y.toDouble(),
            SwiftData.fromByteArray(
                PdfPageWidthsWireCodec.encode(PdfPageWidthsWire(geometryPageWidthsPt.toList())), arena,
            ),
            SwiftData.fromByteArray(PageFramesWireCodec.encode(PageFramesWire(pageFrames)), arena),
            arena,
        ).toByteArray()
        // Empty is the ordinary "tap landed on no page" answer (a gutter, a letterbox margin) — not an error.
        if (hitBytes.isEmpty()) return null
        val hit = try {
            PdfPageHitWireCodec.decode(hitBytes)
        } catch (e: Exception) {
            // Wire skew between this Kotlin codec and the .so — same rationale as `project`'s own decode guard.
            ReaderDiagnostics.recordNonFatal(e)
            return null
        }
        val cursorBytes = SheetMusicJNI.nativePdfHitTest(geometryHandle, hit.pageIndex, hit.x, hit.y)
        if (cursorBytes.isEmpty()) return null
        return try {
            ScoreCursorCodec.decode(cursorBytes)
        } catch (e: Exception) {
            ReaderDiagnostics.recordNonFatal(e)
            null
        }
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
 * published), or `null` while the PDF isn't playable or its setup hasn't landed yet — the surfaces draw no cursor and
 * run no auto-follow then. The value flips from `null` to a projector exactly once per document, so reading it in a
 * surface's body costs one recomposition, like `pdfPlayback` itself.
 *
 * Setup runs in a [produceState] on [Dispatchers.Default], NOT inside a `remember` calculation, for two reasons.
 * It performs one JNI call per page (the page-width check below), which on a 200-page document is 200 synchronous
 * native hops — not something to put on a composition pass, let alone the main thread. And it REPORTS, which a
 * `remember` block must never do: Compose is free to run and discard a composition, and a `remember` re-runs for
 * every surface that mounts, so a layout-mode switch or a rotation would each file another report for the same
 * document.
 *
 * The check itself is the sanity check the cursor's correctness rests on: the side-car's page widths and
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
): PdfCursorProjector? {
    val projector = produceState<PdfCursorProjector?>(null, geometryHandle, renderedPageWidthsPt) {
        value = if (geometryHandle == null) {
            null
        } else {
            withContext(Dispatchers.Default) { buildPdfCursorProjector(geometryHandle, renderedPageWidthsPt) }
        }
    }
    return projector.value
}

/**
 * The geometry handle whose page widths have already been checked-and-reported, so the report is once per DOCUMENT
 * rather than once per surface mounting (a layout-mode switch, a rotation, or a discarded composition each build a
 * fresh projector, and all of them share this).
 *
 * `getAndSet` makes the claim atomic, so two surfaces mounting at once can't both report — the loser reads back the
 * handle it was about to claim and stays quiet. The handle is a sufficient identity here because ssm's `HandleTable`
 * allocates monotonically and never recycles a released value, so a later document can never inherit a claim.
 *
 * This is one slot, not a set: it means "the last document checked", so alternating between two PDFs, or closing and
 * reopening one, files a fresh report each time. That is the intended reading of "once per document" for a
 * diagnostic — it bounds the per-open reports at one, which is what the noise this guards against was.
 */
private val reportedPageWidthCheck = AtomicLong(0L)

/**
 * Fetch the side-car's page sizes, run the once-per-document page-width check, and build the projector. Off-main —
 * see [rememberPdfCursorProjector]'s doc for why none of this may happen during composition. `null` when the
 * side-car has no page sizes for this handle at all (nothing could be placed against it).
 */
private fun buildPdfCursorProjector(geometryHandle: Long, renderedPageWidthsPt: List<Double>): PdfCursorProjector? {
    // Claimed once per document, up front, so BOTH reporting paths below (the decode failure and the width
    // disagreement) are gated by the same claim — a second surface mounting for the same document reports neither.
    val shouldReport = reportedPageWidthCheck.getAndSet(geometryHandle) != geometryHandle

    val sizesBytes = SheetMusicJNI.nativePdfPageSizes(geometryHandle)
    if (sizesBytes.isEmpty()) return null
    val sizes = try {
        PdfPageSizesWireCodec.decode(sizesBytes)
    } catch (e: Exception) {
        if (shouldReport) ReaderDiagnostics.recordNonFatal(e)
        return null
    }
    // A trailing run of pages the importer never recorded is simply not appended, so this array is padded out to the
    // document's real page count with the side-car's own "unknown" encoding (0.0) rather than being indexed short.
    val widths = DoubleArray(renderedPageWidthsPt.size) { sizes.widths.getOrElse(it) { 0.0 } }
    if (shouldReport) reportPageWidthDisagreement(renderedPageWidthsPt, widths)
    return PdfCursorProjector(geometryHandle, widths)
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

    /**
     * A tap in the surface's VIEWPORT space → its world space, for tap-to-seek. The full inverse of the camera the
     * cursor `Canvas` draws through: the content sits at `-scroll` inside the viewport, the fixed [topPadPx] shifts
     * it down without scaling (it is outside the page `Column`'s `graphicsLayer` — the same asymmetry
     * [verticalSpan] encodes), and everything inside that layer is scaled by [zoom]. The horizontal axis has no pad,
     * matching [horizontalSpan].
     *
     * `null` for a non-positive [zoom] — never true in practice (the live/raster ratio of two positive scales), but
     * the division has to be total.
     */
    fun worldPointForTap(
        tap: Offset,
        hScrollPx: Float,
        vScrollPx: Float,
        zoom: Float,
        topPadPx: Float,
    ): Offset? {
        if (zoom <= 0f) return null
        return Offset((tap.x + hScrollPx) / zoom, (tap.y + vScrollPx - topPadPx) / zoom)
    }
}
