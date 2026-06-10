package com.keynumber.folino.reader

/**
 * A–B loop region, measure-granular (A snaps to a measure head, B to a measure end), inclusive of
 * both measures. Mirrors iOS `ABRepeatRange` reduced to the measure indices the engine needs.
 */
data class AbRepeatRange(val startMeasure: Int, val endMeasure: Int) {
    /** Swaps so start <= end (iOS `RepeatLoop.normalize`). */
    fun normalized(): AbRepeatRange =
        if (startMeasure <= endMeasure) this else AbRepeatRange(endMeasure, startMeasure)
}
