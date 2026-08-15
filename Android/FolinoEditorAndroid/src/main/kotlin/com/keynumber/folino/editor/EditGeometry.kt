package com.keynumber.folino.editor

import androidx.compose.ui.geometry.Offset
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.EditCaretFrame
import io.github.jiyimeta.sheetmusic.audio.serialization.EditCaretFrameCodec

/**
 * Tap point (outer viewport px) → document millimetres. Mirrors `nearestCursorForTap`'s (`TapToCursor.kt`)
 * conversion exactly: both invert the same forward transform the cursor/caret overlays draw with
 * (`panOffset + scale * (mm * pxPerMM)`), so the two must stay byte-for-byte identical rather than each carrying
 * its own copy of the arithmetic. Callers that have already gated `pxPerMM`/`scale` against a degenerate value
 * (or want the guard folded in) should go through [tapToDocumentMmOrNull] instead.
 */
fun tapToDocumentMm(tap: Offset, contentOffsetPx: Offset, pxPerMM: Float, scale: Float): Pair<Double, Double> =
    Pair(
        ((tap.x - contentOffsetPx.x) / (pxPerMM * scale)).toDouble(),
        ((tap.y - contentOffsetPx.y) / (pxPerMM * scale)).toDouble(),
    )

/** [tapToDocumentMm], guarded against a zero/negative [pxPerMM] or [scale] — which would otherwise divide out to
 * an infinity or a NaN instead of a real millimetre point. */
fun tapToDocumentMmOrNull(tap: Offset, contentOffsetPx: Offset, pxPerMM: Float, scale: Float): Pair<Double, Double>? {
    if (pxPerMM <= 0f || scale <= 0f) return null
    return tapToDocumentMm(tap, contentOffsetPx, pxPerMM, scale)
}

/**
 * Tap → the `ScoreItemID` bytes an edit intent addresses, or null when the tap hit paper.
 *
 * Null is a real answer, not a failure: ssm's hit-test policy answers "nothing" for a tap that is not on a staff
 * band, and iOS uses exactly that to mean "deselect". An empty array also comes back when the layout is not
 * cached — which, since ssm 1.14.x, is what a relayout overtaken by an edit deliberately leaves behind. Treat it
 * the same way: the tap does nothing and the recompute already in flight will make the next one work.
 */
fun editingHitTestForTap(
    tap: Offset,
    contentOffsetPx: Offset,
    pxPerMM: Float,
    scale: Float,
    scoreHandle: Long,
    activeVoice: Int,
    layoutOptionsBytes: ByteArray,
): ByteArray? {
    val (xMm, yMm) = tapToDocumentMmOrNull(tap, contentOffsetPx, pxPerMM, scale) ?: return null
    val bytes = SheetMusicJNI.nativeEditingHitTest(scoreHandle, xMm, yMm, activeVoice, layoutOptionsBytes)
    return if (bytes.isEmpty()) null else bytes
}

/**
 * The insertion-caret rect (document/mm) for [itemBytes] within the cached layout of [scoreHandle], or null when
 * ssm answers empty — an unknown handle, an uncached layout, undecodable bytes, or a stale ID a reflow already
 * overtook (see [editingHitTestForTap]'s doc comment: the same "empty is a real answer" rule applies here).
 */
fun caretRectMm(scoreHandle: Long, itemBytes: ByteArray, minimumWidthMm: Double): EditCaretFrame? {
    val bytes = SheetMusicJNI.nativeEditingCaretFrame(scoreHandle, itemBytes, minimumWidthMm)
    if (bytes.isEmpty()) return null
    return EditCaretFrameCodec.decode(bytes)
}
