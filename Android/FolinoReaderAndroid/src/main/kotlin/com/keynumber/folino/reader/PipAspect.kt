package com.keynumber.folino.reader

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Android rejects PiP aspect ratios outside roughly `[1/2.39, 2.39]`; a rejected
 * `setAspectRatio` is swallowed and the window falls back to a square. We clamp a touch inside the
 * limit (2.34) so the exact boundary is never hit.
 */
const val PIP_MAX_ASPECT = 2.34

/** Clamp a desired width/height aspect into Android's accepted PiP range. */
fun pipAspectClamped(aspect: Double): Double =
    aspect.coerceIn(1.0 / PIP_MAX_ASPECT, PIP_MAX_ASPECT)

/** Vertical breathing room (each side) left around the system inside the PiP window. Mirrors iOS's
 *  `ScorePiPFrameRenderer.verticalPaddingPt = 16`. Tunable; confirmed by the iOS side-by-side. */
val PIP_VERTICAL_PAD: Dp = 16.dp

/**
 * Render density (pixels per layout-mm) for the PiP score, chosen so the single system's full height
 * fits the current PiP window height with [verticalPadPx] breathing room on each side. Unlike the
 * full-screen Reader (fixed device-independent [fixedPxPerMm]), PiP scales with the window so the
 * whole system stays visible at every PiP size stage — mirroring iOS, where AVKit scales a fixed
 * buffer to the window. Returns 0 for a degenerate viewport / system so callers can no-op.
 */
fun pipFitPxPerMm(
    viewportHeightPx: Int,
    verticalPadPx: Float,
    systemHeightMM: Double,
): Float {
    if (viewportHeightPx <= 0 || systemHeightMM <= 0.0) return 0f
    val usable = viewportHeightPx - 2f * verticalPadPx
    if (usable <= 0f) return 0f
    return (usable / systemHeightMM).toFloat()
}
