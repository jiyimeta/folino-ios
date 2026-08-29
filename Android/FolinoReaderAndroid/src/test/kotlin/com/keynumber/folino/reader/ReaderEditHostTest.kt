package com.keynumber.folino.reader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression guard for [isEditDrivenRecompute] — the decision that lets `ReaderViewModel`'s layout recompute
 * loop skip `RECOMPUTE_DEBOUNCE_MS` for an edit (SP4 Task 3): `EditSessionHost.requestRelayout()` bumps an
 * `editRevision` counter, and a pass whose revision has advanced since the loop's last COMPLETED compute is
 * edit-driven and skips the debounce; every other pass still owes it.
 *
 * `ReaderViewModel(app)` cannot be constructed in this module's JVM test source set — no Robolectric, no
 * Android `Application` (see `RecomputeSkipTest`'s own doc for the same constraint, and
 * `shouldSkipLayoutRecompute`'s doc for why the recompute loop already has a pure-function surface extracted
 * for exactly this reason). [isEditDrivenRecompute] is that same kind of extraction for the debounce
 * decision, so this test exercises it directly rather than the loop, and rather than `RecomputeInputs`'s
 * `equals` — `combine` here has no `distinctUntilChanged` and never consults it; see that class's own doc.
 */
class ReaderEditHostTest {

    @Test
    fun `an advanced edit revision is edit-driven and skips the debounce`() {
        assertTrue(isEditDrivenRecompute(editRevision = 1, previousEditRevision = 0))
    }

    @Test
    fun `an unchanged edit revision is not edit-driven and still owes the debounce`() {
        assertFalse(isEditDrivenRecompute(editRevision = 1, previousEditRevision = 1))
    }

    @Test
    fun `no edit yet (both at zero) still owes the debounce`() {
        assertFalse(isEditDrivenRecompute(editRevision = 0, previousEditRevision = 0))
    }
}
