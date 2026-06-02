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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import com.keynumber.folino.reader.ReaderScreen
import com.keynumber.folino.settings.VersionHistoryBridge
import com.keynumber.folino.ui.library.LibraryScreen
import com.keynumber.folino.ui.licenses.LicensesScreen
import com.keynumber.folino.ui.settings.SettingsPrefs
import com.keynumber.folino.ui.settings.SettingsScreen
import com.keynumber.folino.ui.settings.VersionHistoryItem
import java.net.URLDecoder
import java.net.URLEncoder

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = SettingsPrefs(applicationContext)

        // Spike note: synchronous JNI decode on the main thread before
        // setContent. Acceptable for this PoC (one small asset); production
        // should move the asset read + JNI round-trip off the main thread.
        val json = assets.open("VersionHistory.json").readBytes()
        val versionItems = VersionHistoryBridge.load(json)
            .map { VersionHistoryItem(it.version, it.descriptions) }

        setContent {
            MaterialTheme {
                Surface {
                    // Library is the main screen; Settings opens as a full-screen
                    // destination (Android idiom) reached from a gear icon in the
                    // Library app bar, with a back arrow to return.
                    val rootNav = rememberNavController()
                    NavHost(rootNav, startDestination = "library") {
                        composable("library") {
                            LibraryNavGraph(onOpenSettings = { rootNav.navigate("settings") })
                        }
                        composable("settings") {
                            SettingsNavGraph(prefs, versionItems, onBack = { rootNav.popBackStack() })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LibraryNavGraph(onOpenSettings: () -> Unit) {
    val nav = rememberNavController()
    val context = LocalContext.current
    val vm: LibraryAndroidStoreViewModel =
        viewModel(factory = LibraryVMFactory(context.applicationContext))
    NavHost(nav, startDestination = "list") {
        composable("list") {
            LibraryScreen(
                viewModel = vm,
                onOpenScore = { row ->
                    val t = URLEncoder.encode(row.title, "UTF-8")
                    nav.navigate("reader/${row.id}/$t")
                },
                onOpenSettings = onOpenSettings,
            )
        }
        composable(
            "reader/{id}/{title}",
            arguments = listOf(
                navArgument("id") { type = NavType.StringType },
                navArgument("title") { type = NavType.StringType },
            ),
        ) { entry ->
            val id = entry.arguments?.getString("id") ?: ""
            val title = URLDecoder.decode(entry.arguments?.getString("title") ?: "", "UTF-8")
            ReaderScreen(scoreId = id, title = title, onBack = { nav.popBackStack() })
        }
    }
}

@Composable
private fun SettingsNavGraph(
    prefs: SettingsPrefs,
    versionItems: List<VersionHistoryItem>,
    onBack: () -> Unit,
) {
    val nav = rememberNavController()
    NavHost(nav, startDestination = "settings") {
        composable("settings") {
            SettingsRoute(
                prefs = prefs,
                versionItems = versionItems,
                onBack = onBack,
                onOpenLicenses = { nav.navigate("licenses") },
            )
        }
        composable("licenses") {
            LicensesRoute(onBack = { nav.popBackStack() })
        }
    }
}

// `TopAppBar` lives behind Material3's experimental API surface. Scope the opt-in to the route wrappers.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsRoute(
    prefs: SettingsPrefs,
    versionItems: List<VersionHistoryItem>,
    onBack: () -> Unit,
    onOpenLicenses: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.nav_settings)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding)) {
            SettingsScreen(prefs, versionItems, onOpenLicenses = onOpenLicenses)
        }
    }
}

private class LibraryVMFactory(private val context: android.content.Context) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T =
        LibraryAndroidStoreViewModel.create(
            store = com.keynumber.folino.library.RoomLibraryStore(context),
        ) as T
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LicensesRoute(onBack: () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Licenses") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
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
