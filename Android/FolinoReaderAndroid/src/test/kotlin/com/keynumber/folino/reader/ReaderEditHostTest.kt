package com.keynumber.folino.reader

import com.keynumber.folino.reader.pdf.PdfPlaybackState
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Regression guard for the mechanism that lets an edit drive a relayout (SP4 Task 3): `ReaderViewModel`
 * implements `EditSessionHost.requestRelayout()` by bumping an `editRevision` counter that
 * [startRecomputeLoop]'s `combine(...)` folds into a [RecomputeInputs] value, and `mapLatest` restarts
 * whenever that value changes.
 *
 * `ReaderViewModel(app)` cannot be constructed in this module's JVM test source set — no Robolectric, no
 * Android `Application` (see `RecomputeSkipTest`'s own doc for the same constraint, and
 * `shouldSkipLayoutRecompute`'s doc for why the recompute loop already has a pure-function surface extracted
 * for exactly this reason). So this test exercises the loop's pure input surface instead: two
 * [RecomputeInputs] values differing ONLY in [RecomputeInputs.editRevision] must be unequal. That is what
 * makes `combine`'s emission — built fresh from a `data class` constructor whose auto-generated `equals`
 * covers every property, [editRevision] included — register as a change, which is exactly what restarts
 * `mapLatest` and drives the recompute a note edit needs.
 */
class ReaderEditHostTest {

    @Test
    fun `RecomputeInputs values differing only in editRevision are unequal`() {
        val before = RecomputeInputs(
            scoreHandle = 1L,
            options = LayoutOptions.DEFAULT,
            widthMm = 180.0,
            pdfPlayback = PdfPlaybackState.Idle,
            editRevision = 0,
        )
        val afterRelayoutRequest = before.copy(editRevision = before.editRevision + 1)

        assertNotEquals(before, afterRelayoutRequest)
    }
}
