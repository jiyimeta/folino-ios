package com.keynumber.folino.reader.editing

import com.keynumber.folino.editor.EditAvailability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [editingUnavailableReasonFor] — the pure half of the unavailable-refusal dialog's logic (fix round 1: an
 * Important finding on Task 6's review). The IMPURE half — re-running this on every "Edit notes" tap, not
 * only when `editing.availability` happens to change value — is a Compose `LaunchedEffect` keyed on a
 * per-tap counter in `ReaderScreen`, which has no JVM-testable surface in this module (see
 * `RecomputeSkipTest`'s and `ReaderEditHostTest`'s own docs for the same Robolectric-less constraint). What
 * IS testable is that this function always answers correctly for the CURRENT values, repeat call or not —
 * which is the property the fix actually depends on: re-deriving "version skew" from "version skew" a
 * second time must give the same non-null answer, not silently collapse to null.
 */
class EditingUnavailableReasonTest {

    @Test
    fun `a session in progress never shows a refusal, whatever availability reads`() {
        assertNull(editingUnavailableReasonFor(EditAvailability.AVAILABLE, isEditing = true))
        assertNull(editingUnavailableReasonFor(EditAvailability.UNAVAILABLE_VERSION_SKEW, isEditing = true))
        assertNull(editingUnavailableReasonFor(EditAvailability.UNAVAILABLE_DIVERGED, isEditing = true))
        assertNull(editingUnavailableReasonFor(EditAvailability.UNAVAILABLE_NO_SCORE, isEditing = true))
    }

    @Test
    fun `available and no-score are not shown as a refusal dialog`() {
        // AVAILABLE isn't a failure; NO_SCORE is the PDF-refusal case the composition root gates before
        // `begin()` is ever reachable (see EditingUnavailableDialog's own doc) — neither has a body to show.
        assertNull(editingUnavailableReasonFor(EditAvailability.AVAILABLE, isEditing = false))
        assertNull(editingUnavailableReasonFor(EditAvailability.UNAVAILABLE_NO_SCORE, isEditing = false))
    }

    @Test
    fun `version skew and diverged each surface as themselves, not collapsed to one reason`() {
        assertEquals(
            EditAvailability.UNAVAILABLE_VERSION_SKEW,
            editingUnavailableReasonFor(EditAvailability.UNAVAILABLE_VERSION_SKEW, isEditing = false),
        )
        assertEquals(
            EditAvailability.UNAVAILABLE_DIVERGED,
            editingUnavailableReasonFor(EditAvailability.UNAVAILABLE_DIVERGED, isEditing = false),
        )
    }

    @Test
    fun `a repeat call with the identical failure still answers non-null`() {
        // This is the property the whole fix hinges on: the StateFlow the real caller reads from conflates
        // equal emissions, so a second failed "Edit notes" attempt in a row hands this function the EXACT
        // same (availability, isEditing) pair as the first. The function must not treat "already answered
        // this once" as a reason to go quiet — it has no memory of a previous call at all, which is what
        // makes it safe to call from an effect that re-runs for reasons other than a value change.
        val first = editingUnavailableReasonFor(EditAvailability.UNAVAILABLE_VERSION_SKEW, isEditing = false)
        val second = editingUnavailableReasonFor(EditAvailability.UNAVAILABLE_VERSION_SKEW, isEditing = false)
        assertEquals(EditAvailability.UNAVAILABLE_VERSION_SKEW, first)
        assertEquals(first, second)
    }
}
