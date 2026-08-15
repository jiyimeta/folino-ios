package com.keynumber.folino.reader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [needsLayoutBeforeTinting] — the guard that stops the selection tint replaying a layout it did not ask for.
 *
 * `nativeEncodeDrawProgram` takes no layout arguments: it re-emits whatever document the last `nativeComputeLayout`
 * for that handle left in the engine's single-slot cache. `ReaderViewModel` has four callers that write that slot,
 * and one of them — `horizontalProgram`, the Picture-in-Picture surface — writes it with HORIZONTAL options at a
 * moment the user does not choose, because PiP auto-enters when the app is backgrounded. Return from PiP, tap a
 * note, and without this guard the tint published the horizontal document as the VERTICAL surface's program and the
 * reader silently changed layout mid-edit.
 *
 * `ReaderViewModel(app)` cannot be constructed in this module's JVM test source set — no Robolectric, no Android
 * `Application` (see `RecomputeSkipTest` and `ReaderEditHostTest` for the same constraint), and the native calls
 * have no JNI library to reach. The comparison IS the fix, though, so it is extracted and pinned here; that it runs
 * inside the same `layoutMutex` section as the encode is a review and device-pass concern.
 */
class EditLayoutCacheTest {

    private val vertical = LayoutOptions.DEFAULT.copy(mode = ReaderLayoutMode.VERTICAL)

    private val wanted = CachedLayoutKey(handle = 7L, widthMm = 180.0, heightMm = 297.0, options = vertical)

    @Test
    fun `a cache holding exactly this layout is replayed as is`() {
        assertFalse(needsLayoutBeforeTinting(cached = wanted.copy(), wanted = wanted))
    }

    @Test
    fun `nothing cached yet has to be computed rather than replayed`() {
        assertTrue(needsLayoutBeforeTinting(cached = null, wanted = wanted))
    }

    @Test
    fun `a PiP horizontal pass leaves a layout this surface must not replay`() {
        // The regression this whole seam exists for: same handle, same page size, HORIZONTAL options.
        val afterPip = wanted.copy(
            widthMm = 210.0,
            options = vertical.copy(mode = ReaderLayoutMode.HORIZONTAL),
        )
        assertTrue(needsLayoutBeforeTinting(cached = afterPip, wanted = wanted))
    }

    @Test
    fun `a paged fetch's page geometry is not this surface's layout either`() {
        assertTrue(needsLayoutBeforeTinting(cached = wanted.copy(widthMm = 210.0), wanted = wanted))
        assertTrue(needsLayoutBeforeTinting(cached = wanted.copy(heightMm = 210.0), wanted = wanted))
    }

    @Test
    fun `a layout cached for a different handle is not this score's`() {
        // A resync publishes a fresh handle; the document cached against the retired one describes the score it was
        // engraved from, not the one about to be tinted.
        assertTrue(needsLayoutBeforeTinting(cached = wanted.copy(handle = 8L), wanted = wanted))
    }

    @Test
    fun `a display-settings change since the cached compute has to be re-engraved`() {
        assertTrue(
            needsLayoutBeforeTinting(
                cached = wanted.copy(options = vertical.copy(staffSize = vertical.staffSize + 1.0)),
                wanted = wanted,
            ),
        )
        assertTrue(
            needsLayoutBeforeTinting(
                cached = wanted.copy(options = vertical.copy(hiddenStaves = setOf(StaffAddress(0, 1)))),
                wanted = wanted,
            ),
        )
    }
}
