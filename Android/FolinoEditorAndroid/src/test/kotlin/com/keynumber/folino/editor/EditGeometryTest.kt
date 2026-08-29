package com.keynumber.folino.editor

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for [tapToDocumentMm] / [tapToDocumentMmOrNull] — the px→mm conversion is the part worth pinning here.
 * [editingHitTestForTap] / [caretRectMm] call into the JNI bridge and are not mockable off-device, so they are left
 * to `EditSessionParityTest`'s device coverage.
 */
class EditGeometryTest {
    @Test
    fun `a tap converts to document millimetres the same way the seek path does`() {
        val mm = tapToDocumentMm(
            tap = Offset(100f, 260f),
            contentOffsetPx = Offset(-20f, 40f),
            pxPerMM = 4f,
            scale = 2f,
        )
        assertEquals(15.0, mm.first, 1e-9)
        assertEquals(27.5, mm.second, 1e-9)
    }

    @Test
    fun `a degenerate scale yields no point rather than an infinity`() {
        assertNull(tapToDocumentMmOrNull(Offset.Zero, Offset.Zero, pxPerMM = 4f, scale = 0f))
    }

    @Test
    fun `a degenerate pxPerMM yields no point rather than an infinity`() {
        assertNull(tapToDocumentMmOrNull(Offset.Zero, Offset.Zero, pxPerMM = 0f, scale = 2f))
    }
}
