package com.keynumber.folino.reader

/**
 * One bank-128 drum kit as the mixer's percussion picker needs it.
 *
 * A view-level projection, NOT a catalog: the kit list is owned by shared Swift (`Domain.GMDrumKit`) and
 * reaches this module from the composition root, which is the only layer that can see both the JNI-backed
 * catalog and the Reader. Defining the list here instead would put a second, drifting copy next to the
 * SF2 split's actual presets.
 */
data class DrumKitOption(
    /** Bank-128 program number. */
    val program: Int,
    val displayName: String,
    /** Index into the parallel family-name list; consecutive kits sharing one get a single header. */
    val familyIndex: Int,
)
