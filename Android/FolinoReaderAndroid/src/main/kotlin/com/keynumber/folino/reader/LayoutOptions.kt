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
    /**
     * Whole-score notation transposition in semitones (−7..7; 0 = concert pitch). Per-score, unlike the
     * rest of these, but it rides here because it is another re-spelling applied before layout — the
     * engine re-lays out on any change to this holder, which is exactly what a transpose needs.
     *
     * This is the NOTATION half. The audible half is a tuning shift on the engine
     * (`AndroidPlaybackEngine.setTranspose`); both have to be driven or the score looks transposed
     * while sounding at pitch.
     */
    val transposeSemitones: Int = 0,
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
            transposeSemitones = transposeSemitones,
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

/** Display mode -> DataStore string form. Inverse of [ReaderLayoutMode.fromPref]. */
fun ReaderLayoutMode.toPref(): String = when (this) {
    ReaderLayoutMode.VERTICAL -> "vertical"
    ReaderLayoutMode.HORIZONTAL -> "horizontal"
    ReaderLayoutMode.PAGE -> "page"
}

/** Hidden staves as DataStore string set ("<part>:<staff>"). */
fun LayoutOptions.hiddenStavesPref(): Set<String> = hiddenStaves.map { it.encode() }.toSet()

/** Clef overrides as DataStore string set ("<part>:<staff>=<raw>"). */
fun LayoutOptions.clefOverridesPref(): Set<String> =
    clefOverrides.map { (a, raw) -> "${a.encode()}=$raw" }.toSet()

/** Rebuild a [LayoutOptions] from the flattened SettingsPrefs values. Inverse of the *Pref() projections. */
fun layoutOptionsFromPrefs(
    layoutMode: String,
    staffSize: Double,
    honorBreaks: Boolean,
    collapseRests: Boolean,
    showInvisible: Boolean,
    hiddenStaves: Set<String>,
    clefOverrides: Set<String>,
    /** Per-score, from the ReaderPreferences bridge rather than SettingsPrefs — see [LayoutOptions]. */
    transposeSemitones: Int = 0,
): LayoutOptions = LayoutOptions(
    mode = ReaderLayoutMode.fromPref(layoutMode),
    staffSize = staffSize,
    honorLayoutBreaks = honorBreaks,
    collapseMultiMeasureRests = collapseRests,
    showInvisibleElements = showInvisible,
    hiddenStaves = hiddenStaves.mapNotNull { StaffAddress.parse(it) }.toSet(),
    clefOverrides = clefOverrides.mapNotNull { entry ->
        val eq = entry.indexOf('=')
        if (eq <= 0) return@mapNotNull null
        val addr = StaffAddress.parse(entry.substring(0, eq)) ?: return@mapNotNull null
        addr to entry.substring(eq + 1)
    }.toMap(),
    transposeSemitones = transposeSemitones,
)

/** One staff within a part, for the inspector's Parts section. */
data class StaffDescriptor(val address: StaffAddress, val defaultClefRawType: String)

/**
 * One part (instrument) with its staves, for the inspector's Parts section. [isVisibleInScore] mirrors MuseScore's
 * `<Part><show>` (false when the file authored the part as hidden), from the ssm `PartWire`.
 */
data class PartDescriptor(val name: String, val staves: List<StaffDescriptor>, val isVisibleInScore: Boolean)

/**
 * Staff addresses of every part the file authored as hidden (`isVisibleInScore == false`). Mirrors the shared Swift
 * `Score.authoredHiddenStaffAddresses` — a hidden part contributes all of its staves. The app layer seeds these into
 * the per-score hidden-staff set so an authored-hidden instrument opens hidden by default.
 */
fun List<PartDescriptor>.authoredHiddenStaffAddresses(): Set<StaffAddress> =
    filter { !it.isVisibleInScore }.flatMap { part -> part.staves.map { it.address } }.toSet()

/**
 * Flat `staffIndex -> StaffAddress` map for the mixer. The engine addresses mixer channels by a flat
 * `staffIndex` that enumerates every part's staves in part-then-staff order; the descriptor list is
 * built in that same order ([ReaderViewModel.loadParts]), so the Nth flattened staff's address is the
 * channel at `staffIndex == N`. Used to translate a mixer row's flat index into the per-staff
 * [StaffAddress] the ReaderPreferences bridge persists program / volume overrides against, and to
 * replay persisted overrides (address -> index) onto the engine on open.
 */
fun List<PartDescriptor>.staffAddressByIndex(): Map<Int, StaffAddress> =
    flatMap { it.staves }.mapIndexed { index, staff -> index to staff.address }.toMap()
