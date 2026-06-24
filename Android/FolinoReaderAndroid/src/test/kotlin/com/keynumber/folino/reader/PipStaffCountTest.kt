package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Test

/** Unit tests for [visiblePipStaffCount] — the parity-fix helper that counts present-and-not-hidden staves. */
class PipStaffCountTest {
    private fun part(partIndex: Int, staffCount: Int): PartDescriptor =
        PartDescriptor(
            name = "Part$partIndex",
            staves = (0 until staffCount).map { staffIndex ->
                StaffDescriptor(
                    address = StaffAddress(partIndex, staffIndex),
                    defaultClefRawType = "treble",
                )
            },
        )

    @Test fun allVisibleTwoParts() {
        // 2 parts × 2 staves, none hidden → 4.
        val parts = listOf(part(0, 2), part(1, 2))
        assertEquals(4, visiblePipStaffCount(parts, emptySet()))
    }

    @Test fun oneStaffHiddenReducesCount() {
        // 2 parts × 2 staves, one real staff hidden → 3.
        val parts = listOf(part(0, 2), part(1, 2))
        val hidden = setOf(StaffAddress(0, 1))
        assertEquals(3, visiblePipStaffCount(parts, hidden))
    }

    @Test fun staleHiddenAddressDoesNotReduceCount() {
        // Key parity case: a stale address (not present in any part) must not shrink the count.
        // iOS's Score.filtered(hidingStaves:) only removes staves actually present — this mirrors that.
        val parts = listOf(part(0, 2), part(1, 2))
        val staleAddress = StaffAddress(5, 0) // partIndex 5 does not exist
        assertEquals(4, visiblePipStaffCount(parts, setOf(staleAddress)))
    }

    @Test fun allStavesHiddenClampedToOne() {
        // Every real staff hidden → floor at 1.
        val parts = listOf(part(0, 2))
        val hidden = setOf(StaffAddress(0, 0), StaffAddress(0, 1))
        assertEquals(1, visiblePipStaffCount(parts, hidden))
    }

    @Test fun emptyPartsClampedToOne() {
        assertEquals(1, visiblePipStaffCount(emptyList(), emptySet()))
    }
}
