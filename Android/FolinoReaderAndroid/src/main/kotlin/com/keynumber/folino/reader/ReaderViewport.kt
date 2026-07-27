package com.keynumber.folino.reader

/** Lower bound of the reader's pinch zoom: fit. Zooming out past fit is deliberately not offered. */
internal const val MIN_READER_SCALE = 1f

/** Upper bound of the reader's pinch zoom. */
internal const val MAX_READER_SCALE = 8f

/**
 * Where content sits along one axis when it is SMALLER than the viewport — the case where there is no
 * scrolling to do and the offset is decided rather than chosen.
 *
 * [START] pins it to the leading edge (the vertical surface's top-anchored page). [CENTER] centers it
 * (the horizontal surface's single system, which floats in the middle of a taller viewport).
 */
internal enum class ViewportUnderfill { START, CENTER }

/**
 * Content extent along one axis at [scale], in px.
 *
 * [unitContentPx] is the part that scales with zoom (the page itself at scale 1); [fixedPadPx] is
 * padding that does NOT scale — the vertical surface's breathing room above and below the page, plus its
 * extra bottom pad that lets the last system clear the floating play button.
 */
internal fun axisContentPx(unitContentPx: Float, fixedPadPx: Float, scale: Float): Float =
    unitContentPx * scale + fixedPadPx

/**
 * Clamp a scroll offset along one axis.
 *
 * Positive offset means scrolled forward (down / right), matching `ScrollState.value`. When the content
 * is larger than the viewport the offset rides in `[0, contentPx - viewportPx]`. When it is smaller
 * there is nothing to scroll and [underfill] decides: [ViewportUnderfill.START] pins to zero;
 * [ViewportUnderfill.CENTER] returns a negative offset of half the gap, which the layer's
 * `translation = -offset` turns into a positive lead-in.
 */
internal fun clampAxisOffset(
    offset: Float,
    contentPx: Float,
    viewportPx: Float,
    underfill: ViewportUnderfill,
): Float = if (contentPx <= viewportPx) {
    when (underfill) {
        ViewportUnderfill.START -> 0f
        ViewportUnderfill.CENTER -> (contentPx - viewportPx) / 2f
    }
} else {
    offset.coerceIn(0f, contentPx - viewportPx)
}

/**
 * New scroll offset (px) that keeps the content point under the pinch centroid fixed across a zoom step
 * of ratio `r = newScale / oldScale`. Only the page content scales by `r`; a constant leading [pad] (the
 * fixed padding before the page, which does NOT scale with zoom) is held out of the scaling.
 *
 * In scroll space the content point under the centroid is at `scroll + centroid`; the scaling page part
 * is `scroll + centroid - pad`, so after scaling by `r` the new offset is
 * `pad + r * (scroll - pad + centroid) - centroid`. With `pad = 0` this reduces to the simple
 * `r * (scroll + centroid) - centroid`.
 *
 * The result is NOT clamped here. Clamping is the caller's job and has to happen against the content
 * extent at the NEW scale — the scroll state's clamping at the old extent would have dragged the anchor
 * to the top-left, since the container's `maxValue` still described the previous frame's layout. A caller
 * moving to the new scale must recompute the content extents and clamp the result against those.
 */
internal fun focalAdjustedOffset(
    currentScroll: Float,
    centroid: Float,
    ratio: Float,
    pad: Float = 0f,
): Float = pad + ratio * (currentScroll - pad + centroid) - centroid

/** Clamp a proposed zoom into the reader's supported range. */
internal fun coerceReaderScale(scale: Float): Float = scale.coerceIn(MIN_READER_SCALE, MAX_READER_SCALE)
