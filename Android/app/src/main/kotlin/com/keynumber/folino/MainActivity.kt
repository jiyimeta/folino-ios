package com.keynumber.folino

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import com.keynumber.folino.ui.settings.SettingsPrefs
import com.keynumber.folino.ui.settings.SettingsScreen
import com.keynumber.folino.ui.settings.VersionHistorySource

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = SettingsPrefs(applicationContext)
        setContent {
            MaterialTheme { Surface { SettingsScreen(prefs, VersionHistorySource.placeholder()) } }
        }
    }
}
