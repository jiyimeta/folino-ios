package com.keynumber.folino

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import com.keynumber.folino.settings.VersionHistoryBridge
import com.keynumber.folino.ui.library.LibraryScreen
import com.keynumber.folino.ui.library.ReaderStubScreen
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
                    val rootNav = rememberNavController()
                    Scaffold(
                        bottomBar = {
                            NavigationBar {
                                val current = rootNav.currentBackStackEntryAsState()
                                    .value?.destination?.route
                                NavigationBarItem(
                                    selected = current == "library",
                                    onClick = { rootNav.navigate("library") { launchSingleTop = true } },
                                    icon = { Icon(Icons.Filled.LibraryMusic, contentDescription = null) },
                                    label = { Text(stringResource(R.string.nav_library)) },
                                )
                                NavigationBarItem(
                                    selected = current == "settings",
                                    onClick = { rootNav.navigate("settings") { launchSingleTop = true } },
                                    icon = { Icon(Icons.Filled.Settings, contentDescription = null) },
                                    label = { Text(stringResource(R.string.nav_settings)) },
                                )
                            }
                        },
                    ) { padding ->
                        NavHost(
                            rootNav,
                            startDestination = "library",
                            modifier = Modifier.padding(padding),
                        ) {
                            composable("library") { LibraryNavGraph() }
                            composable("settings") {
                                SettingsNavGraph(prefs, versionItems)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LibraryNavGraph() {
    val nav = rememberNavController()
    val vm: LibraryAndroidStoreViewModel = viewModel(factory = LibraryVMFactory)
    NavHost(nav, startDestination = "list") {
        composable("list") {
            LibraryScreen(vm, onOpenScore = { row ->
                nav.navigate("reader/${URLEncoder.encode(row.title, "UTF-8")}")
            })
        }
        composable(
            "reader/{title}",
            arguments = listOf(navArgument("title") { type = NavType.StringType }),
        ) { entry ->
            val title = URLDecoder.decode(entry.arguments?.getString("title") ?: "", "UTF-8")
            ReaderStubScreen(title = title, onBack = { nav.popBackStack() })
        }
    }
}

@Composable
private fun SettingsNavGraph(prefs: SettingsPrefs, versionItems: List<VersionHistoryItem>) {
    val nav = rememberNavController()
    NavHost(nav, startDestination = "settings") {
        composable("settings") {
            SettingsScreen(prefs, versionItems, onOpenLicenses = { nav.navigate("licenses") })
        }
        composable("licenses") {
            LicensesRoute(onBack = { nav.popBackStack() })
        }
    }
}

private object LibraryVMFactory : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T =
        LibraryAndroidStoreViewModel.create() as T
}

// `TopAppBar` lives behind Material3's experimental API surface. Scoping the opt-in to this single composable keeps
// the rest of MainActivity (notably `onCreate`) free of the experimental marker.
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
