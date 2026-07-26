package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MixerGroupingTest {
    private fun channel(staffIndex: Int, program: Int?, isDrums: Boolean = false) =
        MixerChannel(
            staffIndex = staffIndex,
            displayName = "S$staffIndex",
            program = program,
            isDrums = isDrums,
        )

    @Test
    fun groupsChannelsByPartInPartThenStaffOrder() {
        val addresses = mapOf(
            0 to StaffAddress(partIndex = 0, staffIndexInPart = 0),
            1 to StaffAddress(partIndex = 1, staffIndexInPart = 0),
            2 to StaffAddress(partIndex = 1, staffIndexInPart = 1),
        )
        val channels = listOf(channel(2, 0), channel(0, 40), channel(1, 0))
        val parts = listOf("Violin", "Piano")

        val groups = groupMixerByPart(channels, addresses, parts)

        assertEquals(2, groups.size)
        assertEquals("Violin", groups[0].partName)
        assertEquals(listOf(0), groups[0].channels.map { it.staffIndex })
        assertEquals("Piano", groups[1].partName)
        assertEquals(listOf(1, 2), groups[1].channels.map { it.staffIndex })
    }

    @Test
    fun partProgramIsFirstChannelProgram() {
        val addresses = mapOf(0 to StaffAddress(0, 0), 1 to StaffAddress(0, 1))
        val channels = listOf(channel(0, 24), channel(1, 24))
        val groups = groupMixerByPart(channels, addresses, listOf("Guitar"))
        assertEquals(24, groups[0].partProgram)
    }

    @Test
    fun drumsPartKeepsItsKitProgramAndIsFlagged() {
        val addresses = mapOf(0 to StaffAddress(0, 0))
        // On bank 128 the program is the KIT number, so a percussion part has one like any other.
        // `isDrums` — not a null program — is what tells the picker which catalog to offer.
        val channels = listOf(channel(0, 8, isDrums = true))
        val groups = groupMixerByPart(channels, addresses, listOf("Drums"))
        assertEquals(8, groups[0].partProgram)
        assertTrue(groups[0].isDrums)
    }

    @Test
    fun pitchedPartIsNotFlaggedAsDrums() {
        val addresses = mapOf(0 to StaffAddress(0, 0))
        val groups = groupMixerByPart(listOf(channel(0, 40)), addresses, listOf("Violin"))
        assertFalse(groups[0].isDrums)
    }

    @Test
    fun partWithNoProgramStillGroups() {
        // A part whose program is genuinely absent (nothing selectable) — distinct from percussion,
        // which the old null-program encoding could not express separately.
        val addresses = mapOf(0 to StaffAddress(0, 0))
        val groups = groupMixerByPart(listOf(channel(0, null)), addresses, listOf("Unpitched"))
        assertNull(groups[0].partProgram)
        assertFalse(groups[0].isDrums)
    }
}
