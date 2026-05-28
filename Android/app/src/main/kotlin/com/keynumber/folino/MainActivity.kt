package com.keynumber.folino

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import com.keynumber.folino.settings.VersionHistoryBridge
import com.keynumber.folino.ui.settings.SettingsPrefs
import com.keynumber.folino.ui.settings.SettingsScreen
import com.keynumber.folino.ui.settings.VersionHistoryItem

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = SettingsPrefs(applicationContext)

        // Spike note: synchronous JNI decode on the main thread before
        // setContent. Acceptable for this PoC (one small asset); production
        // should move the asset read + JNI round-trip off the main thread.
        val json = assets.open("VersionHistory.json").readBytes()
        val items = VersionHistoryBridge.load(json)
            .map { VersionHistoryItem(it.version, it.descriptions) }

        setContent {
            MaterialTheme { Surface { SettingsScreen(prefs, items) } }
        }
    }
}
