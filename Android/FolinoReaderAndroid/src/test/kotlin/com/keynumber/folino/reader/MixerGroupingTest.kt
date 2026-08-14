package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import org.junit.Assert.assertEquals
import org.junit.Test

class MixerGroupingTest {
    private fun strip(partIndex: Int, ordinal: Int, name: String = "S$partIndex.$ordinal") =
        MixerChannel(
            partIndex = partIndex,
            ordinal = ordinal,
            liveChannel = partIndex,
            displayName = name,
        )

    @Test
    fun groupsStripsByPartKeepingEngineOrder() {
        val strips = listOf(strip(0, 0), strip(1, 0), strip(1, 1))
        val parts = listOf("Violin", "Piano")

        val groups = groupMixerByPart(strips, parts)

        assertEquals(2, groups.size)
        assertEquals("Violin", groups[0].partName)
        assertEquals(listOf(0), groups[0].strips.map { it.ordinal })
        assertEquals("Piano", groups[1].partName)
        assertEquals(listOf(0, 1), groups[1].strips.map { it.ordinal })
    }

    @Test
    fun aPartsSecondStripStaysWithTheFirst() {
        // The instrument-change case the staff-keyed mixer could not express: one part, two strips, and
        // the second one must be reachable rather than collapsed onto the first.
        val groups = groupMixerByPart(listOf(strip(0, 0, "S"), strip(0, 1, "S (Accordion)")), listOf("S"))

        assertEquals(1, groups.size)
        assertEquals(
            listOf(MixerStripID(0, 0), MixerStripID(0, 1)),
            groups[0].strips.map { it.stripID },
        )
        assertEquals(listOf("S", "S (Accordion)"), groups[0].strips.map { it.displayName })
    }

    @Test
    fun aPartWithNoSuppliedNameFallsBackToItsOrdinal() {
        val groups = groupMixerByPart(listOf(strip(1, 0)), partNames = listOf("Violin"))
        assertEquals("Part 2", groups[0].partName)
    }

    @Test
    fun anEmptyPartNameIsTreatedAsAbsent() {
        val groups = groupMixerByPart(listOf(strip(0, 0)), partNames = listOf(""))
        assertEquals("Part 1", groups[0].partName)
    }
}
