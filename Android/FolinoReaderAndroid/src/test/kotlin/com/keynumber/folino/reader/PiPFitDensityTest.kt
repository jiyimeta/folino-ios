package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PiPFitDensityTest {
    // 600px window − 16px pad each side = 568px usable; 40mm system → 14.2 px/mm.
    @Test fun fitsSystemHeightIntoWindowMinusPadding() {
        assertEquals(14.2, pipFitPxPerMm(600, 16f, 40.0).toDouble(), 0.01)
    }

    @Test fun smallerWindowYieldsSmallerDensity() {
        val large = pipFitPxPerMm(600, 16f, 40.0)
        val small = pipFitPxPerMm(300, 16f, 40.0)
        assertTrue(small < large)
    }

    @Test fun tallerSystemYieldsSmallerDensity() {
        val short = pipFitPxPerMm(600, 16f, 40.0)
        val tall = pipFitPxPerMm(600, 16f, 80.0)
        assertTrue(tall < short)
    }

    @Test fun degenerateInputsReturnZero() {
        assertEquals(0f, pipFitPxPerMm(0, 16f, 40.0))     // no viewport
        assertEquals(0f, pipFitPxPerMm(600, 16f, 0.0))    // no system height
        assertEquals(0f, pipFitPxPerMm(20, 16f, 40.0))    // padding consumes the whole window
    }
}
