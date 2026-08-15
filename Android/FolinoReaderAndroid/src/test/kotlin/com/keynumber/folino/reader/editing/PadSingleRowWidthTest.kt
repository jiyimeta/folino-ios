package com.keynumber.folino.reader.editing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards against the class of bug review caught in Task 7's fix round 1: `SINGLE_ROW_MIN_WIDTH` was a
 * hand-picked `640.dp`, but `SingleRow` actually needs ~705.dp (14 keys at 44.dp + one ~5.dp divider + 14 gaps
 * at 6.dp) — so any measured card width in [640.dp, 705.dp) picked the single-row layout and it ran off the
 * card, unscrollable and unclipped.
 *
 * These tests don't pin the NUMBER (that would just re-encode the same mistake the next time a key is added —
 * the tuplet/tie keys are explicitly coming in a later pass and will widen the row). They pin the
 * RELATIONSHIP: [SINGLE_ROW_MIN_WIDTH] is derived from the same building blocks [SingleRow] lays out with
 * ([SINGLE_ROW_KEY_COUNT], [KEY_MIN_WIDTH], [SINGLE_ROW_GAP], [DIVIDER_FOOTPRINT_WIDTH]), so the threshold used
 * to pick the layout and the width the layout actually needs cannot drift apart independently.
 */
class PadSingleRowWidthTest {
    @Test
    fun `singleRowRequiredWidthDp's arithmetic matches a hand-worked example`() {
        // 5 duration + 1 dot + 7 pitch + 1 rest = 14 keys, 15 children with the divider, 14 gaps between them:
        // 14*44 + 5 + 14*6 = 616 + 5 + 84 = 705 — the exact shortfall review found against the old 640.dp constant.
        val required = singleRowRequiredWidthDp(
            keyCount = 14,
            keyWidthDp = 44f,
            gapDp = 6f,
            dividerFootprintDp = 5f,
        )
        assertEquals(705f, required, 0f)
    }

    @Test
    fun `SINGLE_ROW_KEY_COUNT matches what the row's own key groups emit`() {
        // Duration keys (PadDuration.ordered) + 1 dot key + pitch keys (PITCH_LETTERS) + 1 rest key, read from
        // the SAME lists SingleRow's own key groups iterate — not a copy of "5" and "7". If a key group's count
        // changes without SINGLE_ROW_KEY_COUNT changing too, this is the test that catches it.
        assertEquals(PadDuration.ordered.size + 1 + PITCH_LETTERS.size + 1, SINGLE_ROW_KEY_COUNT)
    }

    @Test
    fun `the pad's actual single-row threshold never undercounts what SingleRow needs`() {
        val actuallyRequired = singleRowRequiredWidthDp(
            keyCount = SINGLE_ROW_KEY_COUNT,
            keyWidthDp = KEY_MIN_WIDTH.value,
            gapDp = SINGLE_ROW_GAP.value,
            dividerFootprintDp = DIVIDER_FOOTPRINT_WIDTH.value,
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
