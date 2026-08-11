package com.keynumber.folino.reader

import android.content.Context

/**
 * What an untouched (`null` on the Swift side) per-score Reader preference resolves to on this device.
 *
 * Keyed on `smallestScreenWidthDp` — the device's smaller dimension, which does not change when the device rotates or
 * when a window is resized. These values are what "the user never chose" resolves to, so a rule driven by the live
 * window width would re-engrave every untouched score mid-session. The `>= 600` cut is Android's own tablet
 * convention (`sw600dp`).
 *
 * The two values move together on purpose. A phone viewport is narrower than the page the score was engraved for, so
 * honoring the authored layout breaks leaves the staves cramped against an empty right margin; wrapping to the
 * viewport at a smaller staff size is what makes the same score readable.
 *
 * iOS resolves the same pair from `UIDevice.userInterfaceIdiom` (`ReaderDeviceDefaults.swift`). The numbers differ
 * between the platforms because Android engraves at a fixed layout density, so the same millimetre value renders at a
 * different apparent size.
 */
object ReaderDeviceDefaults {
    private const val TABLET_MIN_WIDTH_DP = 600

    /** Engraved staff size for a score the user has never sized themselves. */
    fun staffSize(smallestScreenWidthDp: Int): Double =
        if (smallestScreenWidthDp >= TABLET_MIN_WIDTH_DP) 24.0 else 21.0

    /** Whether a score the user has never configured reproduces the engraver's authored system / page boundaries. */
    fun honorLayoutBreaks(smallestScreenWidthDp: Int): Boolean =
        smallestScreenWidthDp >= TABLET_MIN_WIDTH_DP

    fun staffSize(context: Context): Double =
        staffSize(context.resources.configuration.smallestScreenWidthDp)

    fun honorLayoutBreaks(context: Context): Boolean =
        honorLayoutBreaks(context.resources.configuration.smallestScreenWidthDp)
}
