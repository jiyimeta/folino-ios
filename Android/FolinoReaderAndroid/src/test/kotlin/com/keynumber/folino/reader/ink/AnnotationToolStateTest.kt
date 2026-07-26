package com.keynumber.folino.reader.ink

import org.junit.Assert.assertEquals
import org.junit.Test

class AnnotationToolStateTest {
    @Test fun activeWidthFollowsTheSelectedPen() {
        val s = AnnotationToolState(
            selected = AnnotationTool.Pen(2),
            penWidths = listOf(0.6f, 1.2f, 3.2f, 2.0f),
        )
        assertEquals(3.2f, s.activeWidth, 1e-6f)
    }

    @Test fun activeWidthFollowsTheEraser() {
        val s = AnnotationToolState(selected = AnnotationTool.Eraser, eraserWidth = 8f)
        assertEquals(8f, s.activeWidth, 1e-6f)
    }

    @Test fun settingAWidthOnlyTouchesTheSelectedPen() {
        val s = AnnotationToolState(selected = AnnotationTool.Pen(1))
            .withWidthForSelected(3.2f)
        assertEquals(3.2f, s.penWidths[1], 1e-6f)
        assertEquals(AnnotationWidths.PEN_DEFAULTS[0], s.penWidths[0], 1e-6f)
        assertEquals(AnnotationWidths.ERASER_PRESETS[1], s.eraserWidth, 1e-6f)
    }

    @Test fun settingAWidthOnTheEraserLeavesPensAlone() {
        val s = AnnotationToolState(selected = AnnotationTool.Eraser).withWidthForSelected(14f)
        assertEquals(14f, s.eraserWidth, 1e-6f)
        assertEquals(AnnotationWidths.PEN_DEFAULTS, s.penWidths)
    }

    @Test fun presetIndexSnapsToTheNearestPreset() {
        assertEquals(1, AnnotationWidths.presetIndex(AnnotationWidths.PEN_PRESETS, 1.2f))
        assertEquals(3, AnnotationWidths.presetIndex(AnnotationWidths.PEN_PRESETS, 99f))
        assertEquals(0, AnnotationWidths.presetIndex(AnnotationWidths.PEN_PRESETS, 0f))
    }

    @Test fun presetIndexSnapsToNearestForInteriorValues() {
        assertEquals(2, AnnotationWidths.presetIndex(AnnotationWidths.PEN_PRESETS, 1.9f)) // nearest 2.0, not floor 1.2
        assertEquals(1, AnnotationWidths.presetIndex(AnnotationWidths.PEN_PRESETS, 1.3f)) // nearest 1.2
    }

    @Test fun presetTablesHoldTheSpecifiedValues() {
        assertEquals(listOf(0.6f, 1.2f, 2.0f, 3.2f), AnnotationWidths.PEN_PRESETS)
        assertEquals(listOf(2.0f, 4.0f, 8.0f, 14.0f), AnnotationWidths.ERASER_PRESETS)
        assertEquals(listOf(1.2f, 1.2f, 1.2f, 1.2f), AnnotationWidths.PEN_DEFAULTS)
    }

    @Test fun defaultPenWidthMatchesTheShippingWidth() {
        assertEquals(1.2f, AnnotationToolState().activeWidth, 1e-6f)
    }
}
