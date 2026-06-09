package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ReaderRepeatControllerTest {

    /** Builds a controller over mutable test state; `currentMeasure` drives the playhead. */
    private class Harness(
        initialMode: RepeatMode = RepeatMode.AB_LOOP,
        initialRange: AbRepeatRange? = null,
        startMeasure: Int? = 0,
    ) {
        val log = mutableListOf<String>()
        var currentMeasure: Int? = startMeasure
        val controller = ReaderRepeatController(
            currentMeasureProvider = { currentMeasure },
            persistedRangeLoader = { initialRange },
            persistRange = { r -> log.add("persist:$r") },
            persistMode = { m -> log.add("mode:${m.wire}") },
            applyLoop = { range, mode -> log.add("loop:${mode.wire}:$range") },
            initialMode = initialMode,
        )
    }

    @Test fun setA_thenSetB_buildsNormalizedRange() {
        val h = Harness(startMeasure = 2)
        h.controller.setA()
        h.currentMeasure = 5
        h.controller.setB()
        assertEquals(AbRepeatRange(2, 5), h.controller.abRange.value)
        assertEquals("loop:abLoop:AbRepeatRange(startMeasure=2, endMeasure=5)", h.log.last())
    }

    @Test fun setB_beforeA_isIncomplete_noLoop() {
        val h = Harness(startMeasure = 3)
        h.controller.setB()
        assertNull(h.controller.abRange.value) // incomplete -> no committed range
    }

    @Test fun setA_swapsWhenAfterB() {
        val h = Harness(startMeasure = 5)
        h.controller.setA()
        h.currentMeasure = 2
        h.controller.setB()
        assertEquals(AbRepeatRange(2, 5), h.controller.abRange.value) // normalized
    }

    @Test fun reTapSameMeasureClearsThatEndpoint() {
        val h = Harness(startMeasure = 2)
        h.controller.setA()
        h.currentMeasure = 5
        h.controller.setB() // range 2..5
        assertEquals(AbRepeatRange(2, 5), h.controller.abRange.value)
        h.currentMeasure = 2
        h.controller.setA() // re-tap A's measure -> clear A
        assertNull(h.controller.abRange.value) // range becomes incomplete
    }

    @Test fun modeOff_clearsLoop() {
        val h = Harness(initialMode = RepeatMode.AB_LOOP, initialRange = AbRepeatRange(1, 2))
        h.controller.setMode(RepeatMode.OFF)
        assertEquals("loop:off:null", h.log.last())
    }

    @Test fun modeLoopAll_appliesFullScore() {
        val h = Harness(initialMode = RepeatMode.OFF)
        h.controller.setMode(RepeatMode.LOOP_ALL)
        // range null => applyLoop interprets LOOP_ALL as full score
        assertEquals("loop:loopAll:null", h.log.last())
    }

    @Test fun restoresPersistedRangeAtConstruction() {
        val h = Harness(initialMode = RepeatMode.AB_LOOP, initialRange = AbRepeatRange(3, 7))
        assertEquals(AbRepeatRange(3, 7), h.controller.abRange.value)
    }
}
