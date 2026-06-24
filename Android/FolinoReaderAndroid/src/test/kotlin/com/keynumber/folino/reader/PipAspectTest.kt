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
}
