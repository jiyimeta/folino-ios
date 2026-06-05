package com.keynumber.folino.reader

import androidx.compose.ui.geometry.Offset
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec

/**
 * Converts a tap in a render surface's local pixel space to document millimetres, runs the shared
 * nearest-cursor hit-test over JNI, and decodes the resulting full-score engine cursor.
 *
 * All three Reader surfaces (vertical / horizontal / paged) draw the score at `pxPerMM * scale` and
 * the cursor overlay maps document-mm → screen px as `panOffset + scale * (mm * pxPerMM)` (see
 * `PlaybackCursorOverlay`). Inverting that single forward transform is the only px→mm math in the
 * Reader, so it lives here and every surface shares it. Each surface supplies the leading offsets
 * (scroll / page-band / pan) that place its local tap point into the same content space the overlay
 * draws in; this helper applies the common divide-by-(pxPerMM * scale).
 *
 * @param tap          the tap location in the surface's local px space (already de-padded/de-scrolled
 *                     into content-origin space by the [contentOffsetPx] the caller passes).
 * @param contentOffsetPx leading content offset to subtract from [tap] before the divide. This folds
 *                     in scroll offsets, the fixed vertical padding, the page-band top, and pan so the
 *                     resulting point is relative to the document origin (0,0 = top-left of the page
 *                     at mm coordinates). x and y are independent.
 * @param pxPerMM      the surface's fit scale (px per document-mm at unit zoom).
 * @param scale        the user pinch-zoom factor.
 * @param scoreHandle  the laid-out score handle.
 * @param layoutOptionsBytes the SAME `LayoutOptionsWire` blob the Reader feeds `nativeComputeLayout`
 *                     (the hit-test reads only its hidden-staff set and re-addresses against the full
 *                     score).
 * @return the decoded full-score [ScoreCursor], or null when the tap hit nothing playable.
 */
fun nearestCursorForTap(
    tap: Offset,
    contentOffsetPx: Offset,
    pxPerMM: Float,
    scale: Float,
    scoreHandle: Long,
    layoutOptionsBytes: ByteArray,
): ScoreCursor? {
    if (pxPerMM <= 0f || scale <= 0f) return null
    val tapXmm = ((tap.x - contentOffsetPx.x) / (pxPerMM * scale)).toDouble()
    val tapYmm = ((tap.y - contentOffsetPx.y) / (pxPerMM * scale)).toDouble()
    val bytes = SheetMusicJNI.nativeNearestCursor(scoreHandle, tapXmm, tapYmm, layoutOptionsBytes)
    if (bytes.isEmpty()) return null
    return ScoreCursorCodec.decode(bytes)
}
