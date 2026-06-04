package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.ClefOverrideWire
import io.github.jiyimeta.sheetmusic.HiddenStaffWire
import io.github.jiyimeta.sheetmusic.LayoutOptionsWire
import io.github.jiyimeta.sheetmusic.LayoutOptionsWireCodec

/** Positional staff address mirroring Swift StaffAddress: parts[partIndex].staves[staffIndexInPart]. */
data class StaffAddress(val partIndex: Int, val staffIndexInPart: Int) {
    /** DataStore string form "<part>:<staff>". */
    fun encode(): String = "$partIndex:$staffIndexInPart"

    companion object {
        fun parse(s: String): StaffAddress? {
            val (p, st) = s.split(":").takeIf { it.size == 2 } ?: return null
            return StaffAddress(p.toIntOrNull() ?: return null, st.toIntOrNull() ?: return null)
        }
    }
}

/** Immutable snapshot of the Reader's display settings, encodable to the JNI options blob. */
data class LayoutOptions(
    val mode: ReaderLayoutMode,
    val staffSize: Double,
    val honorLayoutBreaks: Boolean,
    val collapseMultiMeasureRests: Boolean,
    val showInvisibleElements: Boolean,
    val hiddenStaves: Set<StaffAddress>,
    val clefOverrides: Map<StaffAddress, String>,
) {
    fun encode(): ByteArray = LayoutOptionsWireCodec.encode(
        LayoutOptionsWire(
            // Pass the REAL display mode (VERTICAL/HORIZONTAL/PAGE -> 0/1/2). The
            // horizontal/page RENDER surfaces are owned by parallel sessions; this
            // holder only produces the mode-appropriate layout program contract.
            layoutMode = when (mode) {
                ReaderLayoutMode.VERTICAL -> 0u
                ReaderLayoutMode.HORIZONTAL -> 1u
                ReaderLayoutMode.PAGE -> 2u
            },
            staffSize = staffSize,
            honorLayoutBreaks = if (honorLayoutBreaks) 1u else 0u,
            collapseMultiMeasureRests = if (collapseMultiMeasureRests) 1u else 0u,
            showsInvisibleElements = if (showInvisibleElements) 1u else 0u,
            hiddenStaves = hiddenStaves.map { HiddenStaffWire(it.partIndex, it.staffIndexInPart) },
            clefOverrides = clefOverrides.map { (a, raw) -> ClefOverrideWire(a.partIndex, a.staffIndexInPart, raw) },
        ),
    )

    companion object {
        /** Defaults matching the SettingsPrefs display-flow defaults (page mode, 28.0 staff, honor breaks). */
        val DEFAULT = LayoutOptions(
            mode = ReaderLayoutMode.PAGE,
            staffSize = 28.0,
            honorLayoutBreaks = true,
            collapseMultiMeasureRests = false,
            showInvisibleElements = false,
            hiddenStaves = emptySet(),
            clefOverrides = emptyMap(),
        )
    }
}

/** One staff within a part, for the inspector's Parts section. */
data class StaffDescriptor(val address: StaffAddress, val defaultClefRawType: String)

/** One part (instrument) with its staves, for the inspector's Parts section. */
data class PartDescriptor(val name: String, val staves: List<StaffDescriptor>)
