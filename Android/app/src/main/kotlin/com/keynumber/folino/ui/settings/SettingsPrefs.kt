package com.keynumber.folino.ui.settings

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

val Context.dataStore by preferencesDataStore(name = "folino_settings")

object SettingsKeys {
    val metronomeEnabled = booleanPreferencesKey("reader.metronome.enabled")
    val pipEnabled = booleanPreferencesKey("reader.pictureInPicture.enabled")
    val collapseRests = booleanPreferencesKey("reader.collapseMultiMeasureRests")
    val keepAwake = booleanPreferencesKey("reader.keepScreenAwake.enabled")
    val layoutMode = stringPreferencesKey("reader.layoutMode") // "vertical" | "horizontal" | "page"
    val staffSize = doublePreferencesKey("reader.staffSize")
    val honorBreaks = booleanPreferencesKey("reader.honorLayoutBreaks")
    val showInvisible = booleanPreferencesKey("reader.showInvisibleElements")
    /**
     * Each element encodes a hidden staff address as `"<partIndex>:<staffIndexInPart>"`,
     * e.g. `"0:1"` means part 0, second staff. Callers build and parse the strings.
     */
    val hiddenStaves = stringSetPreferencesKey("reader.hiddenStaves")
    /**
     * Each element encodes a clef override as `"<partIndex>:<staffIndexInPart>=<rawType>"`,
     * e.g. `"0:1=F8va"` means part 0, second staff, overridden to bass-8va clef.
     * Callers build and parse the strings; rawType matches the sheet-music engine's clef type names.
     */
    val clefOverrides = stringSetPreferencesKey("reader.clefOverrides")
    /** Set once the user has interacted with the page-mode tap-zone overlay; suppresses the onboarding hint. */
    val pageTapHintDismissed = booleanPreferencesKey("reader.pageTapHintDismissed")
    /**
     * Global A4 reference pitch in Hz. Shared key with the iOS side so both platforms default to
     * the same persisted value when reading a cross-platform DataStore export.
     */
    val a4ReferenceHz = doublePreferencesKey("reader.a4ReferenceHz")
    /**
     * Whether Crashlytics crash-data collection is enabled. Opt-out semantics:
     * absent (first launch) is treated as `true`, mirroring iOS
     * `privacyCrashReportingEnabled`. The toggle is an opt-*out*.
     */
    val crashReportingEnabled = booleanPreferencesKey("privacy.crashReporting.enabled")
}

class SettingsPrefs(private val context: Context) {
    val metronome: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.metronomeEnabled] ?: false }
    val pip: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.pipEnabled] ?: false }
    val collapseRests: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.collapseRests] ?: false }
    val keepAwake: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.keepAwake] ?: true }
    val layoutMode: Flow<String> = context.dataStore.data.map { it[SettingsKeys.layoutMode] ?: "page" }
    val staffSize: Flow<Double> = context.dataStore.data.map { it[SettingsKeys.staffSize] ?: 28.0 }
    val honorBreaks: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.honorBreaks] ?: true }
    val showInvisible: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.showInvisible] ?: false }
    val hiddenStaves: Flow<Set<String>> = context.dataStore.data.map { it[SettingsKeys.hiddenStaves] ?: emptySet() }
    val clefOverrides: Flow<Set<String>> = context.dataStore.data.map { it[SettingsKeys.clefOverrides] ?: emptySet() }
    val pageTapHintDismissed: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.pageTapHintDismissed] ?: false }
    val a4ReferenceHz: Flow<Double> = context.dataStore.data.map { it[SettingsKeys.a4ReferenceHz] ?: 440.0 }
    val crashReporting: Flow<Boolean> =
        context.dataStore.data.map { it[SettingsKeys.crashReportingEnabled] ?: true }

    suspend fun setMetronome(v: Boolean) = context.dataStore.edit { it[SettingsKeys.metronomeEnabled] = v }
    suspend fun setPip(v: Boolean) = context.dataStore.edit { it[SettingsKeys.pipEnabled] = v }
    suspend fun setCollapseRests(v: Boolean) = context.dataStore.edit { it[SettingsKeys.collapseRests] = v }
    suspend fun setKeepAwake(v: Boolean) = context.dataStore.edit { it[SettingsKeys.keepAwake] = v }
    suspend fun setLayoutMode(v: String) = context.dataStore.edit { it[SettingsKeys.layoutMode] = v }
    suspend fun setStaffSize(v: Double) = context.dataStore.edit { it[SettingsKeys.staffSize] = v }
    suspend fun setHonorBreaks(v: Boolean) = context.dataStore.edit { it[SettingsKeys.honorBreaks] = v }
    suspend fun setShowInvisible(v: Boolean) = context.dataStore.edit { it[SettingsKeys.showInvisible] = v }
    suspend fun setHiddenStaves(v: Set<String>) = context.dataStore.edit { it[SettingsKeys.hiddenStaves] = v }
    suspend fun setClefOverrides(v: Set<String>) = context.dataStore.edit { it[SettingsKeys.clefOverrides] = v }
    suspend fun setPageTapHintDismissed() = context.dataStore.edit { it[SettingsKeys.pageTapHintDismissed] = true }
    suspend fun setA4ReferenceHz(v: Double) = context.dataStore.edit { it[SettingsKeys.a4ReferenceHz] = v }

    suspend fun setCrashReporting(v: Boolean) =
        context.dataStore.edit { it[SettingsKeys.crashReportingEnabled] = v }
}
