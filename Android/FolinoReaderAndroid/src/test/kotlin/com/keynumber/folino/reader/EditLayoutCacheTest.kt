package com.keynumber.folino.reader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [needsLayoutRepair] — the guard that stops any reader of the engine's layout cache replaying a document it did not
 * ask for.
 *
 * `nativeEncodeDrawProgram` (the selection tint), `nativeEditingHitTest` (an editing tap) and
 * `nativeEditingCaretFrame` (the caret and the callout) all take no layout arguments: they answer from whatever
 * document the last `nativeComputeLayout` for that handle left in the engine's single-slot cache. `ReaderViewModel`
 * has callers that write that slot, and one of them — `horizontalProgram`, the Picture-in-Picture surface — writes it
 * with HORIZONTAL options at a moment the user does not choose, because PiP auto-enters when the app is
 * backgrounded. Return from PiP, tap a note, and without this guard the tint published the horizontal document as the
 * VERTICAL surface's program while the hit test answered with a `ScoreItemID` naming a DIFFERENT element — which then
 * became the target of the next pad key.
 *
 * All three readers now go through `ReaderViewModel.withReaderLayout` (and its non-suspending fast path
 * `tryWithReaderLayout`), which asks exactly this question with the lock held. `ReaderViewModel(app)` cannot be
 * constructed in this module's JVM test source set — no Robolectric, no Android `Application` (see `RecomputeSkipTest`
 * and `ReaderEditHostTest` for the same constraint), and the native calls have no JNI library to reach. The
 * comparison IS the fix, though, so it is extracted and pinned here; that it runs inside the same `layoutMutex`
 * section as the read is a review and device-pass concern.
 */
class EditLayoutCacheTest {

    private val vertical = LayoutOptions.DEFAULT.copy(mode = ReaderLayoutMode.VERTICAL)

    private val wanted = CachedLayoutKey(handle = 7L, widthMm = 180.0, heightMm = 297.0, options = vertical)

    @Test
    fun `a cache holding exactly this layout is replayed as is`() {
        assertFalse(needsLayoutRepair(cached = wanted.copy(), wanted = wanted))
    }

    @Test
    fun `nothing cached yet has to be computed rather than replayed`() {
        assertTrue(needsLayoutRepair(cached = null, wanted = wanted))
    }

    @Test
    fun `a PiP horizontal pass leaves a layout this surface must not replay`() {
        // The regression this whole seam exists for: same handle, same page size, HORIZONTAL options.
        val afterPip = wanted.copy(
            widthMm = 210.0,
            options = vertical.copy(mode = ReaderLayoutMode.HORIZONTAL),
        )
        assertTrue(needsLayoutRepair(cached = afterPip, wanted = wanted))
    }

    @Test
    fun `a PiP pass at this surface's own width is still a foreign layout`() {
        // The mode alone must decide it. PiP feeds `horizontalProgram` a seed width that is irrelevant to a
        // single-system layout, so a guard that only compared geometry would call this cache usable — and the hit
        // test would then resolve a tap against a document laid out as one long system.
        assertTrue(
            needsLayoutRepair(
                cached = wanted.copy(options = vertical.copy(mode = ReaderLayoutMode.HORIZONTAL)),
                wanted = wanted,
            ),
        )
    }

    @Test
    fun `a paged fetch's page geometry is not this surface's layout either`() {
        assertTrue(needsLayoutRepair(cached = wanted.copy(widthMm = 210.0), wanted = wanted))
        assertTrue(needsLayoutRepair(cached = wanted.copy(heightMm = 210.0), wanted = wanted))
        assertTrue(
            needsLayoutRepair(
                cached = wanted.copy(options = vertical.copy(mode = ReaderLayoutMode.PAGE)),
                wanted = wanted,
            ),
        )
    }

    @Test
    fun `a layout cached for a different handle is not this score's`() {
        // A resync publishes a fresh handle; the document cached against the retired one describes the score it was
        // engraved from, not the one about to be tinted.
        assertTrue(needsLayoutRepair(cached = wanted.copy(handle = 8L), wanted = wanted))
    }

    @Test
    fun `a display-settings change since the cached compute has to be re-engraved`() {
        assertTrue(
            needsLayoutRepair(
                cached = wanted.copy(options = vertical.copy(staffSize = vertical.staffSize + 1.0)),
                wanted = wanted,
            ),
        )
        assertTrue(
            needsLayoutRepair(
                cached = wanted.copy(options = vertical.copy(hiddenStaves = setOf(StaffAddress(0, 1)))),
                wanted = wanted,
            ),
        )
    }

    @Test
    fun `a hidden-staff or clef change is foreign even though the page geometry matches`() {
        // Both of these move element numbering or the staff set the hit test re-stamps across, so a tap resolved
        // against the stale document can answer with an ID that addresses a different staff's element.
        assertTrue(
            needsLayoutRepair(
                cached = wanted.copy(options = vertical.copy(clefOverrides = mapOf(StaffAddress(0, 0) to "bass"))),
                wanted = wanted,
            ),
        )
        val collapseFlipped = vertical.copy(collapseMultiMeasureRests = !vertical.collapseMultiMeasureRests)
        assertTrue(needsLayoutRepair(cached = wanted.copy(options = collapseFlipped), wanted = wanted))
    }
}
