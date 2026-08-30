package com.keynumber.folino.reader.editing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards against the class of bug review caught in Task 7's fix round 1: `SINGLE_ROW_MIN_WIDTH` was a
 * hand-picked `640.dp`, but `SingleRow` actually needed ~705.dp (14 keys at 44.dp + one ~5.dp divider + 14 gaps
 * at 6.dp) — so any measured card width in [640.dp, 705.dp) picked the single-row layout and it ran off the
 * card, unscrollable and unclipped.
 *
 * These tests don't pin the NUMBER (that would just re-encode the same mistake the next time a key is added —
 * and five keys HAVE been added since: the tuplet, tie and add-to-chord keys and the two ← / → steppers, each
 * of which moved the threshold with nothing to update by hand). They pin the RELATIONSHIP:
 * [SINGLE_ROW_MIN_WIDTH] is derived from the same building blocks [SingleRow] lays out with
 * ([SINGLE_ROW_KEY_COUNT], [KEY_MIN_WIDTH], [SINGLE_ROW_GAP], [DIVIDER_FOOTPRINT_WIDTH],
 * [SINGLE_ROW_DIVIDER_COUNT]), so the threshold used to pick the layout and the width the layout actually needs
 * cannot drift apart independently.
 */
class PadSingleRowWidthTest {
    @Test
    fun `singleRowRequiredWidthDp's arithmetic matches a hand-worked example`() {
        // The row as it stood when this bug was found: 5 duration + 1 dot + 7 pitch + 1 rest = 14 keys, 15
        // children with its one divider, 14 gaps between them: 14*44 + 5 + 14*6 = 616 + 5 + 84 = 705 — the exact
        // shortfall review found against the old 640.dp constant. Kept as a fixed example (rather than re-derived
        // from today's constants) precisely so it still describes that arithmetic after the row grew.
        val required = singleRowRequiredWidthDp(
            keyCount = 14,
            keyWidthDp = 44f,
            gapDp = 6f,
            dividerFootprintDp = 5f,
            dividerCount = 1,
        )
        assertEquals(705f, required, 0f)
    }

    @Test
    fun `every divider is billed for, not just the first`() {
        // The row's job groups are separated by more than one divider now (arm / navigate / write), and each
        // costs the row both its own footprint and one more gap. A version of this arithmetic that assumed a
        // single divider would undercount by exactly that much — the same shape of mistake as the original.
        fun width(dividerCount: Int) = singleRowRequiredWidthDp(
            keyCount = 10, keyWidthDp = 44f, gapDp = 6f, dividerFootprintDp = 5f, dividerCount = dividerCount,
        )
        assertEquals(5f + 6f, width(2) - width(1), 0f)
    }

    @Test
    fun `SINGLE_ROW_KEY_COUNT matches what the row's own key groups emit`() {
        // Duration keys (PadDuration.ordered) + the tuplet, tie, dot and add-to-chord keys + pitch keys
        // (PITCH_LETTERS) + 1 rest key, read from the SAME lists SingleRow's own key groups iterate — not a copy
        // of "5" and "7". If a key group's count changes without SINGLE_ROW_KEY_COUNT changing too, this is the
        // test that catches it. (The two ← / → steppers used to be counted here; they are their own pill now —
        // see `EditingStepperPill`.)
        assertEquals(PadDuration.ordered.size + 4 + PITCH_LETTERS.size + 1, SINGLE_ROW_KEY_COUNT)
    }

    @Test
    fun `the pad's actual single-row threshold never undercounts what SingleRow needs`() {
        val actuallyRequired = singleRowRequiredWidthDp(
            keyCount = SINGLE_ROW_KEY_COUNT,
            keyWidthDp = KEY_MIN_WIDTH.value,
            gapDp = SINGLE_ROW_GAP.value,
            dividerFootprintDp = DIVIDER_FOOTPRINT_WIDTH.value,
            dividerCount = SINGLE_ROW_DIVIDER_COUNT,
        )
        // Not equality: the invariant that matters is that the threshold BoxWithConstraints compares against
        // never sits below what the row actually needs — <= is what "the threshold and the layout cannot
        // disagree" means, even if a future change makes the derivation add slack on top.
        assertTrue(
            "SINGLE_ROW_MIN_WIDTH (${SINGLE_ROW_MIN_WIDTH.value}) undercounts SingleRow's real requirement " +
                "($actuallyRequired) — the single row would overflow before the threshold picks the stacked " +
                "fallback.",
            actuallyRequired <= SINGLE_ROW_MIN_WIDTH.value,
        )
    }
}
