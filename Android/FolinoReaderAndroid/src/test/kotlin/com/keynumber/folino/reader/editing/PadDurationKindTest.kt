package com.keynumber.folino.reader.editing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [PadDuration.ordered]'s `kind` values against `EditorBridge.armDuration(kind:)`'s arming vocabulary
 * (`NoteDurationWire`'s discriminator: 1 = whole ... 9 = 256th, 10 = measure, 11 = fraction).
 *
 * Kind 11 (`.fraction`) is EMIT-only — `EditorBridge.duration(fromKind:)` has no `case` for it and
 * `armDuration(kind:)` silently no-ops when handed it. A pad key built from the emit-side vocabulary (which does
 * include 11, since a written note can already be a tuplet-scaled fraction) would be a dead key with nothing to
 * catch it — this test is that catch.
 */
class PadDurationKindTest {
    @Test
    fun `the pad arms only the kinds the bridge accepts`() {
        assertEquals(listOf(1, 2, 3, 4, 5), PadDuration.ordered.map { it.kind })
        assertTrue(PadDuration.ordered.none { it.kind == 11 })
    }
}
