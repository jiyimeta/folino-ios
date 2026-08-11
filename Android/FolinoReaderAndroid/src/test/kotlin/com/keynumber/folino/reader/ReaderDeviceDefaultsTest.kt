package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The defaults an untouched per-score Reader preference resolves to. The tablet cut is `smallestScreenWidthDp >= 600`
 * — the smallest dimension, so it does not move when the device rotates.
 */
class ReaderDeviceDefaultsTest {
    @Test fun phoneGetsTheNarrowPair() {
        assertEquals(21.0, ReaderDeviceDefaults.staffSize(smallestScreenWidthDp = 411), 0.0)
        assertFalse(ReaderDeviceDefaults.honorLayoutBreaks(smallestScreenWidthDp = 411))
    }

    @Test fun tabletGetsTheWidePair() {
        assertEquals(24.0, ReaderDeviceDefaults.staffSize(smallestScreenWidthDp = 800), 0.0)
        assertTrue(ReaderDeviceDefaults.honorLayoutBreaks(smallestScreenWidthDp = 800))
    }

    @Test fun theCutIsAtSixHundred() {
        assertEquals(21.0, ReaderDeviceDefaults.staffSize(smallestScreenWidthDp = 599), 0.0)
        assertEquals(24.0, ReaderDeviceDefaults.staffSize(smallestScreenWidthDp = 600), 0.0)
        assertFalse(ReaderDeviceDefaults.honorLayoutBreaks(smallestScreenWidthDp = 599))
        assertTrue(ReaderDeviceDefaults.honorLayoutBreaks(smallestScreenWidthDp = 600))
    }
}
