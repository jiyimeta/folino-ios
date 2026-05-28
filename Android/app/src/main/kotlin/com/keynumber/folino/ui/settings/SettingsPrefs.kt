package com.keynumber.folino.ui.settings

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
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
}

class SettingsPrefs(private val context: Context) {
    val metronome: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.metronomeEnabled] ?: false }
    val pip: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.pipEnabled] ?: false }
    val collapseRests: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.collapseRests] ?: false }
    val keepAwake: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.keepAwake] ?: true }
    val layoutMode: Flow<String> = context.dataStore.data.map { it[SettingsKeys.layoutMode] ?: "page" }

    suspend fun setMetronome(v: Boolean) = context.dataStore.edit { it[SettingsKeys.metronomeEnabled] = v }
    suspend fun setPip(v: Boolean) = context.dataStore.edit { it[SettingsKeys.pipEnabled] = v }
    suspend fun setCollapseRests(v: Boolean) = context.dataStore.edit { it[SettingsKeys.collapseRests] = v }
    suspend fun setKeepAwake(v: Boolean) = context.dataStore.edit { it[SettingsKeys.keepAwake] = v }
    suspend fun setLayoutMode(v: String) = context.dataStore.edit { it[SettingsKeys.layoutMode] = v }
}
