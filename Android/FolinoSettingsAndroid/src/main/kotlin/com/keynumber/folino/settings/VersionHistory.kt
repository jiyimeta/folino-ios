package com.keynumber.folino.settings

import java.util.Locale

// VersionHistoryWireListCodec + VersionHistoryWire are wirelet-generated
// (emitModels=true). They live in this same package under build/generated/.

/**
 * Loads the version history by round-tripping the `VersionHistory.yml` asset bytes through
 * Swift: [SettingsJNI.nativeLoadVersionHistory] returns a wirelet-encoded
 * `VersionHistoryWireList`, which [VersionHistoryWireListCodec] decodes back
 * into Kotlin model objects.
 */
object VersionHistoryBridge {
    /**
     * @param languageTag the language whose translations the descriptions come back in; defaults to the
     * device language. Swift cannot read it for itself — see [SettingsJNI.nativeLoadVersionHistory].
     */
    fun load(
        ymlBytes: ByteArray,
        languageTag: String = Locale.getDefault().toLanguageTag(),
    ): List<VersionHistoryWire> =
        VersionHistoryWireListCodec.decode(SettingsJNI.nativeLoadVersionHistory(ymlBytes, languageTag)).entries
}
