package com.keynumber.folino

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.keynumber.folino.settings.VersionHistoryBridge
import com.keynumber.folino.ui.licenses.LicensesScreen
import com.keynumber.folino.ui.settings.SettingsPrefs
import com.keynumber.folino.ui.settings.SettingsScreen
import com.keynumber.folino.ui.settings.VersionHistoryItem

@OptIn(ExperimentalMaterial3Api::class)
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
            MaterialTheme {
                Surface {
                    val nav = rememberNavController()
                    NavHost(nav, startDestination = "settings") {
                        composable("settings") {
                            SettingsScreen(prefs, items, onOpenLicenses = { nav.navigate("licenses") })
                        }
                        composable("licenses") {
                            Scaffold(
                                topBar = {
                                    TopAppBar(
                                        title = { Text("Licenses") },
                                        navigationIcon = {
                                            IconButton(onClick = { nav.popBackStack() }) {
                                                Icon(
                                                    Icons.AutoMirrored.Filled.ArrowBack,
                                                    contentDescription = "Back",
                                                )
                                            }
                                        },
                                    )
                                },
                            ) { padding ->
                                Box(Modifier.padding(padding)) { LicensesScreen() }
                            }
                        }
                    }
                }
            }
        }
    }
}
