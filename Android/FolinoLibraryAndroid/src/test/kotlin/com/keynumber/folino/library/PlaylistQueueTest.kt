package com.keynumber.folino.library

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaylistQueueTest {
    private fun item(pl: String, score: String, pos: Int) = PlaylistItemWire(pl, score, pos)
    // addedAt is irrelevant to queue ordering (playlists keep their manual position order), so every
    // fixture shares one value.
    private fun score(id: String, deletedAt: Double) = ScoreRecordWire(
        id = id, title = id, subtitle = "", composer = "",
        localFileName = "$id.mscz", contentHash = "", deletedAt = deletedAt,
        lastOpenedAt = 0.0, isFavorite = false, addedAt = 0.0,
    )

    @Test fun ordersByPosition_filtersToRequestedPlaylist_andLiveScoresOnly() {
        val items = listOf(
            item("P1", "c", 2), item("P1", "a", 0), item("P1", "b", 1),
            item("P2", "z", 0),
        )
        val scores = listOf(
            score("a", 0.0), score("b", 12.0), score("c", 0.0), score("z", 0.0),
        )
        // "b" is soft-deleted (deletedAt != 0) → skipped; "z" belongs to P2 → excluded.
        assertEquals(listOf("a", "c"), orderedLivePlaylistScoreIds(items, scores, "P1"))
    }

    @Test fun emptyWhenPlaylistUnknown() {
        assertEquals(emptyList<String>(), orderedLivePlaylistScoreIds(emptyList(), emptyList(), "P1"))
    }
}
