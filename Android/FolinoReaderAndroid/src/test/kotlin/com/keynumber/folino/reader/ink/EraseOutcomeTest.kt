package com.keynumber.folino.reader.ink

import com.keynumber.folino.reader.DrawingAnchorWire
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the "did the erase actually change anything?" predicate the gesture handler gates its publish on.
 * The regression this pins: `changedIndices` lists only SPLIT/TRIMMED fragments, so a gesture that only
 * fully-erased (dropped) strokes has an empty `changedIndices` yet a genuinely shorter layer. Gating on
 * `changedIndices` alone made small remnants un-erasable no matter how hard the eraser scrubbed.
 */
class EraseOutcomeTest {
    // Trailing 0, -1 are anchorKind (musical) and pageIndex (unused for musical anchors); this test only cares about
    // erase's list-shape bookkeeping, not anchor kind.
    private fun layer(n: Int) = List(n) { DrawingAnchorWire(0, 0, 0, 0, 0.0, 0.0, ByteArray(0), 0, -1) }

    @Test fun fullyErasingAStrokeChangesTheLayerEvenWithNoFragments() {
        // Pure drop: the eraser covered a whole stroke, so it's absent from the output and nothing split.
        val outcome = EraseOutcome(drawings = layer(2), changedIndices = emptyList())
        assertTrue(outcome.changesLayer(baseSize = 3))
    }

    @Test fun aMissChangesNothing() {
        val outcome = EraseOutcome(drawings = layer(3), changedIndices = emptyList())
        assertFalse(outcome.changesLayer(baseSize = 3))
    }

    @Test fun trimmingAStrokeChangesTheLayerAtTheSameCount() {
        // One end of a stroke erased → a single fragment replaces it: same count, flagged by changedIndices.
        val outcome = EraseOutcome(drawings = layer(3), changedIndices = listOf(1))
        assertTrue(outcome.changesLayer(baseSize = 3))
    }

    @Test fun splittingAStrokeChangesTheLayer() {
        // One stroke split into two fragments → the layer grew and changedIndices is non-empty.
        val outcome = EraseOutcome(drawings = layer(4), changedIndices = listOf(1, 2))
        assertTrue(outcome.changesLayer(baseSize = 3))
    }
}
