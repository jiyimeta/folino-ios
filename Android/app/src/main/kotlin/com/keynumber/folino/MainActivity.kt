package com.keynumber.folino

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import com.keynumber.folino.reader.ReaderScreen
import com.keynumber.folino.settings.VersionHistoryBridge
import com.keynumber.folino.ui.library.LibraryScreen
import androidx.compose.material.icons.automirrored.outlined.Label
import com.keynumber.folino.ui.library.PlaylistDetailScreen
import com.keynumber.folino.ui.library.PlaylistsListScreen
import com.keynumber.folino.ui.library.RecentlyDeletedScreen
import com.keynumber.folino.ui.library.TagDetailScreen
import com.keynumber.folino.ui.library.TagsListScreen
import com.keynumber.folino.ui.licenses.LicensesScreen
import com.keynumber.folino.ui.settings.SettingsPrefs
import com.keynumber.folino.ui.settings.SettingsScreen
import com.keynumber.folino.ui.settings.VersionHistoryItem
import kotlinx.coroutines.launch
import java.net.URLDecoder
import java.net.URLEncoder

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = SettingsPrefs(applicationContext)

        // Spike note: synchronous JNI decode on the main thread before
        // setContent. Acceptable for this PoC (one small asset); production
        // should move the asset read + JNI round-trip off the main thread.
        val yml = assets.open("VersionHistory.yml").readBytes()
        val versionItems = VersionHistoryBridge.load(yml)
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

    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val currentRoute = nav.currentBackStackEntryAsState().value?.destination?.route
    // Reader is a detail pushed on top; only the top-level list destinations
    // expose the drawer (hamburger + edge swipe).
    val drawerCapable = currentRoute == "list" || currentRoute == "recentlyDeleted" ||
        currentRoute == "playlists" || currentRoute == "tags"

    fun switchTo(route: String) {
        scope.launch { drawerState.close() }
        if (currentRoute != route) {
            nav.navigate(route) {
                popUpTo(nav.graph.findStartDestination().id) { saveState = true }
                launchSingleTop = true
                restoreState = true
            }
        }
    }

    // Library row tap → push the Reader, addressed by score id (Reader resolves
    // filesDir/Scores/<id>.mscz); title rides along for the app bar.
    val openReader: (com.keynumber.folino.library.ScoreRowWire) -> Unit = { row ->
        val t = URLEncoder.encode(row.title, "UTF-8")
        nav.navigate("reader/${row.id}/$t")
    }

    ModalNavigationDrawer(
        drawerState = drawerState,
        gesturesEnabled = drawerCapable,
        drawerContent = {
            ModalDrawerSheet {
                Spacer(Modifier.height(12.dp))
                Text(
                    stringResource(R.string.library_title),
                    style = MaterialTheme.typography.titleLarge,
                    modifier = Modifier.padding(horizontal = 28.dp, vertical = 16.dp),
                )
                NavigationDrawerItem(
                    icon = { Icon(Icons.Filled.LibraryMusic, contentDescription = null) },
                    label = { Text(stringResource(R.string.nav_all_scores)) },
                    selected = currentRoute == "list",
                    onClick = { switchTo("list") },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
                NavigationDrawerItem(
                    icon = { Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = null) },
                    label = { Text(stringResource(R.string.nav_playlists)) },
                    selected = currentRoute == "playlists",
                    onClick = { switchTo("playlists") },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
                NavigationDrawerItem(
                    icon = { Icon(Icons.AutoMirrored.Outlined.Label, contentDescription = null) },
                    label = { Text(stringResource(R.string.nav_tags)) },
                    selected = currentRoute == "tags",
                    onClick = { switchTo("tags") },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
                NavigationDrawerItem(
                    icon = { Icon(Icons.Filled.Delete, contentDescription = null) },
                    label = { Text(stringResource(R.string.library_recently_deleted)) },
                    selected = currentRoute == "recentlyDeleted",
                    onClick = { switchTo("recentlyDeleted") },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
                HorizontalDivider(Modifier.padding(vertical = 8.dp))
                NavigationDrawerItem(
                    icon = { Icon(Icons.Filled.Settings, contentDescription = null) },
                    label = { Text(stringResource(R.string.nav_settings)) },
                    selected = false,
                    onClick = {
                        scope.launch { drawerState.close() }
                        onOpenSettings()
                    },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
            }
        },
    ) {
        val openDrawer: () -> Unit = { scope.launch { drawerState.open() } }
        NavHost(nav, startDestination = "list") {
            composable("list") {
                LibraryScreen(
                    viewModel = vm,
                    onOpenScore = openReader,
                    onOpenDrawer = openDrawer,
                )
            }
            composable("recentlyDeleted") {
                RecentlyDeletedScreen(
                    viewModel = vm,
                    onOpenScore = openReader,
                    onOpenDrawer = openDrawer,
                )
            }
            composable("playlists") {
                PlaylistsListScreen(
                    viewModel = vm,
                    onOpenPlaylist = { id, name ->
                        nav.navigate("playlist/$id/${URLEncoder.encode(name, "UTF-8")}")
                    },
                    onOpenDrawer = openDrawer,
                )
            }
            composable(
                "playlist/{id}/{name}",
                arguments = listOf(
                    navArgument("id") { type = NavType.StringType },
                    navArgument("name") { type = NavType.StringType },
                ),
            ) { entry ->
                val id = entry.arguments?.getString("id") ?: ""
                val name = URLDecoder.decode(entry.arguments?.getString("name") ?: "", "UTF-8")
                PlaylistDetailScreen(
                    viewModel = vm,
                    playlistId = id,
                    playlistName = name,
                    onOpenScore = openReader,
                    onBack = { nav.popBackStack() },
                )
            }
            composable("tags") {
                TagsListScreen(
                    viewModel = vm,
                    onOpenTag = { id, name ->
                        nav.navigate("tag/$id/${URLEncoder.encode(name, "UTF-8")}")
                    },
                    onOpenDrawer = openDrawer,
                )
            }
            composable(
                "tag/{id}/{name}",
                arguments = listOf(
                    navArgument("id") { type = NavType.StringType },
                    navArgument("name") { type = NavType.StringType },
                ),
            ) { entry ->
                val id = entry.arguments?.getString("id") ?: ""
                val name = URLDecoder.decode(entry.arguments?.getString("name") ?: "", "UTF-8")
                TagDetailScreen(
                    viewModel = vm,
                    tagId = id,
                    tagName = name,
                    onOpenScore = openReader,
                    onBack = { nav.popBackStack() },
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
