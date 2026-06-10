package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MixerGroupingTest {
    private fun channel(staffIndex: Int, program: Int?) =
        MixerChannel(
            staffIndex = staffIndex,
            displayName = "S$staffIndex",
            program = program,
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
    fun drumsPartHasNullProgram() {
        val addresses = mapOf(0 to StaffAddress(0, 0))
        val channels = listOf(channel(0, null))
        val groups = groupMixerByPart(channels, addresses, listOf("Drums"))
        assertNull(groups[0].partProgram)
    }
}
