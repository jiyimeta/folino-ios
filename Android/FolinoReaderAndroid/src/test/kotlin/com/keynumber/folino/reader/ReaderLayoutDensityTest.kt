package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Test

class ReaderLayoutDensityTest {
    // A ~393dp phone lays out ~210mm regardless of pixel density (device-independent).
    @Test fun phoneWidthMmIs210AtDensity1() {
        assertEquals(210.0, layoutWidthMm(widthPx = 393, densityPxPerDp = 1.0f), 0.5)
    }

    @Test fun phoneWidthMmIs210AtDensity2() {
        assertEquals(210.0, layoutWidthMm(widthPx = 786, densityPxPerDp = 2.0f), 0.5)
    }

    // A ~800dp tablet lays out ~427mm — roughly twice the music at the same staff size.
    @Test fun tabletWidthMmIsRoughlyDouble() {
        assertEquals(427.5, layoutWidthMm(widthPx = 1600, densityPxPerDp = 2.0f), 1.0)
    }

    // pxPerMm and widthMm are exact inverses: widthPx round-trips.
    @Test fun pxPerMmInvertsWidthMm() {
        val px = 1080
        val d = 2.625f
        val mm = layoutWidthMm(px, d)
        assertEquals(px.toDouble(), mm * fixedPxPerMm(d), 0.5)
    }

    @Test fun nonPositiveInputClampsToMin() {
        assertEquals(80.0, layoutWidthMm(0, 2.0f), 1e-9)
        assertEquals(80.0, layoutWidthMm(100, 0f), 1e-9)
    }
}
