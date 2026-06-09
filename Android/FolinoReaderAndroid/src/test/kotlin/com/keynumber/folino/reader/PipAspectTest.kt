package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Test

class PipAspectTest {
    @Test fun singleStaffClampsToAndroidMax() {
        // iOS heuristic 6.0/1 = 6.0, clamped to Android's 2.39 max.
        assertEquals(2.39, pipAspectClamped(1), 1e-9)
    }

    @Test fun twoStavesClampToAndroidMax() {
        // 6.0/2 = 3.0 -> clamped to 2.39.
        assertEquals(2.39, pipAspectClamped(2), 1e-9)
    }

    @Test fun threeStavesStaysBelowMax() {
        // 6.0/3 = 2.0, within range.
        assertEquals(2.0, pipAspectClamped(3), 1e-9)
    }

    @Test fun sixStavesIsSquare() {
        // 6.0/6 = 1.0 (the iOS lower clamp).
        assertEquals(1.0, pipAspectClamped(6), 1e-9)
    }

    @Test fun manyStavesClampToOne() {
        // 6.0/12 = 0.5 -> clamped up to 1.0.
        assertEquals(1.0, pipAspectClamped(12), 1e-9)
    }

    @Test fun zeroOrNegativeTreatedAsOneStaff() {
        assertEquals(2.39, pipAspectClamped(0), 1e-9)
        assertEquals(2.39, pipAspectClamped(-5), 1e-9)
    }
}
