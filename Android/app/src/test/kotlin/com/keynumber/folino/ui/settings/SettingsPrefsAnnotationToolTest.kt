package com.keynumber.folino.ui.settings

import com.keynumber.folino.reader.ink.AnnotationTool
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The DataStore round trip itself needs instrumentation (see [SettingsPrefs.annotationToolState] /
 * [SettingsPrefs.setAnnotationToolState]), so this only covers what's unit-testable off-device: the
 * TOTAL [encodeAnnotationTool] / [decodeAnnotationTool] pair and its defensive decoding.
 */
class SettingsPrefsAnnotationToolTest {
    @Test fun roundTripsAPenSelection() {
        val encoded = encodeAnnotationTool(AnnotationTool.Pen(2))
        assertEquals("pen:2", encoded)
        assertEquals(AnnotationTool.Pen(2), decodeAnnotationTool(encoded))
    }

    @Test fun roundTripsTheEraserSelection() {
        val encoded = encodeAnnotationTool(AnnotationTool.Eraser)
        assertEquals("eraser", encoded)
        assertEquals(AnnotationTool.Eraser, decodeAnnotationTool(encoded))
    }

    @Test fun decodeIsTotalForAMissingValue() {
        assertEquals(AnnotationTool.Pen(0), decodeAnnotationTool(null))
    }

    @Test fun decodeIsTotalForAnUnrecognizedString() {
        assertEquals(AnnotationTool.Pen(0), decodeAnnotationTool("garbage"))
    }

    @Test fun decodeIsTotalForAnOutOfRangePenIndex() {
        assertEquals(AnnotationTool.Pen(0), decodeAnnotationTool("pen:9"))
    }

    @Test fun decodeIsTotalForANonNumericPenIndex() {
        assertEquals(AnnotationTool.Pen(0), decodeAnnotationTool("pen:x"))
    }

    @Test fun decodeIsTotalForABareNumericStringWithNoPrefix() {
        assertEquals(AnnotationTool.Pen(0), decodeAnnotationTool("2"))
    }

    @Test fun decodeIsTotalForAnEmptyString() {
        assertEquals(AnnotationTool.Pen(0), decodeAnnotationTool(""))
    }
}
