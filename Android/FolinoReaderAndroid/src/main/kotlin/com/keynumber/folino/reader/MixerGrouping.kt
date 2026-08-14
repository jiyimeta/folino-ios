package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel

/**
 * Identity of one mixer strip — one independently controllable sound: one fader, one mute, one solo, one
 * program. Mirrors Domain's `MixerStripID`, and is the pair the engine addresses channels by.
 *
 * [instrumentOrdinal] counts a part's *distinct instruments* in order of first appearance, not its staves: a
 * grand staff is two staves and one strip, while a part that changes instrument mid-score is one staff and
 * several. The dedup rule that produces it lives in swift-sheet-music and is deliberately not reproduced here.
 */
data class MixerStripID(val partIndex: Int, val instrumentOrdinal: Int)

/** The strip this channel controls. */
val MixerChannel.stripID: MixerStripID
    get() = MixerStripID(partIndex, ordinal)

/**
 * One part's slice of the mixer: its display name and the strips belonging to it, in the order the engine
 * reported them.
 */
data class PartMixerGroup(
    val partIndex: Int,
    val partName: String,
    val strips: List<MixerChannel>,
)

/**
 * Regroup the engine's strip list into per-part groups, mirroring the iOS playback inspector's "Parts"
 * section. [partNames] supplies each part's display name by index.
 *
 * Engine order is preserved rather than re-sorted — `mixerChannels` already comes out by part, then by
 * ordinal, and that is the order iOS draws. `groupBy` keeps encounter order, so both levels follow.
 */
fun groupMixerByPart(
    strips: List<MixerChannel>,
    partNames: List<String>,
): List<PartMixerGroup> =
    strips.groupBy { it.partIndex }.map { (partIndex, ofPart) ->
        PartMixerGroup(
            partIndex = partIndex,
            partName = partNames.getOrNull(partIndex)?.takeIf { it.isNotEmpty() }
                ?: "Part ${partIndex + 1}",
            strips = ofPart,
        )
    }
