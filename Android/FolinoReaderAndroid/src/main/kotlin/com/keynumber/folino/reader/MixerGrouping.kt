package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel

/**
 * One part's slice of the flat mixer: its display name, the staff channels that belong to it (in
 * staff-in-part order), and the part-level program (the first channel's program).
 *
 * [isDrums] — not a null [partProgram] — is what marks a percussion part. On bank 128 the program is the
 * KIT number, so drum parts have one too; conflating "percussion" with "no program" is what previously
 * left them with no picker at all.
 */
data class PartMixerGroup(
    val partIndex: Int,
    val partName: String,
    val partProgram: Int?,
    val isDrums: Boolean,
    val channels: List<MixerChannel>,
)

/**
 * Regroup the engine's flat [channels] into per-part groups, mirroring the iOS playback inspector's
 * "Parts" section. [staffAddressByIndex] maps a channel's flat `staffIndex` to its positional
 * [StaffAddress] (part + staff-in-part); [partNames] supplies each part's display name by index.
 * Channels with no resolvable address are dropped. Within a part, channels are ordered by
 * staff-in-part; parts are ordered by part index. The part program is the first channel's program.
 */
fun groupMixerByPart(
    channels: List<MixerChannel>,
    staffAddressByIndex: Map<Int, StaffAddress>,
    partNames: List<String>,
): List<PartMixerGroup> {
    val byPart = channels
        .mapNotNull { ch -> staffAddressByIndex[ch.staffIndex]?.let { addr -> addr to ch } }
        .groupBy { it.first.partIndex }
    return byPart.keys.sorted().map { partIndex ->
        val ordered = byPart.getValue(partIndex)
            .sortedBy { it.first.staffIndexInPart }
            .map { it.second }
        PartMixerGroup(
            partIndex = partIndex,
            partName = partNames.getOrNull(partIndex)?.takeIf { it.isNotEmpty() }
                ?: "Part ${partIndex + 1}",
            partProgram = ordered.firstOrNull()?.program,
            isDrums = ordered.firstOrNull()?.isDrums == true,
            channels = ordered,
        )
    }
}
