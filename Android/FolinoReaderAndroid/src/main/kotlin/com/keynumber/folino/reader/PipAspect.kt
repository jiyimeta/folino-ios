package com.keynumber.folino.reader

/**
 * Android PiP windows accept an aspect ratio (width / height) within roughly `[1/2.39, 2.39]`;
 * values outside throw from `PictureInPictureParams.setAspectRatio`.
 */
const val PIP_MAX_ASPECT = 2.39

/**
 * PiP window aspect ratio (width / height) from the score's staff count, mirroring the iOS
 * heuristic (`6.0 / staffCount`, clamped to `1.0…6.0`) and then clamped into Android's allowed
 * range. Wide single-system scores sit at the max; busier scores get a squarer window.
 */
fun pipAspectClamped(staffCount: Int): Double {
    val staves = staffCount.coerceAtLeast(1)
    val ios = (6.0 / staves).coerceIn(1.0, 6.0)
    return ios.coerceIn(1.0 / PIP_MAX_ASPECT, PIP_MAX_ASPECT)
}
