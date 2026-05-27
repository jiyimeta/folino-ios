package com.keynumber.folino.ui.settings

object VersionHistorySource {
    // P3 placeholder. P4 replaces this with Swift-decoded entries.
    fun placeholder(): List<VersionHistoryItem> = listOf(
        VersionHistoryItem("1.5.1", listOf("Placeholder — replaced by Swift in P4")),
    )
}
