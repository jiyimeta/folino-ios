package com.keynumber.folino.settings

// VersionHistoryWireListCodec + VersionHistoryWire are wirelet-generated
// (emitModels=true). They live in this same package under build/generated/.

/**
 * Loads the version history by round-tripping the JSON asset bytes through
 * Swift: [SettingsJNI.nativeLoadVersionHistory] returns a wirelet-encoded
 * `VersionHistoryWireList`, which [VersionHistoryWireListCodec] decodes back
 * into Kotlin model objects.
 */
object VersionHistoryBridge {
    fun load(jsonBytes: ByteArray): List<VersionHistoryWire> =
        VersionHistoryWireListCodec.decode(SettingsJNI.nativeLoadVersionHistory(jsonBytes)).entries
}
