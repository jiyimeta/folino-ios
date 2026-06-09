package com.keynumber.folino.soundfont

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import java.io.File

private val Context.soundfontDataStore by preferencesDataStore(name = "folino_soundfont")
private val OPTED_IN = booleanPreferencesKey("soundfont.museScoreGeneral.optedIn")

/**
 * Kotlin implementation of the generated `@WireletProvided` `SoundfontPrefsStore` interface. Persists the opt-in
 * flag in DataStore (default `true`, parity with iOS UserDefaults) and owns the `filesDir/Soundfonts` location.
 *
 * The Swift store calls these synchronously on the JNI thread, so reads/writes block on the DataStore flow. The
 * payload is a single boolean, so the cost is negligible.
 */
class SoundfontPrefsStoreImpl(context: Context) : SoundfontPrefsStore {
    private val appContext = context.applicationContext
    private val dir: File = File(appContext.filesDir, "Soundfonts").apply { mkdirs() }

    override fun loadOptedIn(): Boolean = runBlocking {
        appContext.soundfontDataStore.data.first()[OPTED_IN] ?: true
    }

    override fun saveOptedIn(value: Boolean): Unit = runBlocking {
        appContext.soundfontDataStore.edit { it[OPTED_IN] = value }
        Unit
    }

    override fun soundfontsDirectoryPath(): String = dir.absolutePath
}
