package com.keynumber.folino.reader

/**
 * Reader repeat mode. Mirrors iOS `Domain.RepeatMode`; [wire] equals the iOS rawValue so a
 * cross-platform preference export round-trips. Global & sticky (persisted in DataStore).
 */
enum class RepeatMode(val wire: String) {
    OFF("off"),
    LOOP_ALL("loopAll"),
    AB_LOOP("abLoop");

    companion object {
        fun fromWire(raw: String?): RepeatMode = entries.firstOrNull { it.wire == raw } ?: OFF
    }
}
