package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Test

class PipAspectTest {
    @Test fun clampWideToMax() {
        assertEquals(2.34, pipAspectClamped(7.0), 1e-9)
    }

    @Test fun clampTallToMin() {
        assertEquals(1.0 / 2.34, pipAspectClamped(0.1), 1e-9)
    }

    @Test fun inRangeUnchanged() {
        assertEquals(1.5, pipAspectClamped(1.5), 1e-9)
    }

    @Test fun thinStaffGivesWideWindowClampedToMax() {
        // 30mm system at 210mm fit → 210/(30*1.06) ≈ 6.6 → clamped to the 2.34 max.
        assertEquals(2.34, pipAspectForSystemHeight(30.0, 210.0), 1e-9)
    }

    @Test fun tallSystemGivesSquarerWindow() {
        // 120mm system → 210/(120*1.06) ≈ 1.65, within range, unclamped.
        assertEquals(210.0 / (120.0 * 1.06), pipAspectForSystemHeight(120.0, 210.0), 1e-9)
    }

    @Test fun nonPositiveFallsBackToMax() {
        assertEquals(2.34, pipAspectForSystemHeight(0.0, 210.0), 1e-9)
        assertEquals(2.34, pipAspectForSystemHeight(120.0, 0.0), 1e-9)
    }
}
