package com.keynumber.folino

import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.os.Build
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
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.keynumber.folino.library.ReaderPreferencesController
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import com.keynumber.folino.library.generated.ReaderPreferencesBridgeViewModel
import androidx.core.content.ContextCompat
import com.keynumber.folino.reader.PipHost
import com.keynumber.folino.reader.AbRepeatRange
import com.keynumber.folino.reader.RepeatMode
import com.keynumber.folino.reader.ReaderLayoutMode
import com.keynumber.folino.reader.ReaderPipController
import com.keynumber.folino.reader.ReaderScreen
import com.keynumber.folino.reader.clefOverridesPref
import com.keynumber.folino.reader.hiddenStavesPref
import com.keynumber.folino.reader.layoutOptionsFromPrefs
import com.keynumber.folino.reader.toPref
import com.keynumber.folino.diagnostics.CrashReporting
import com.keynumber.folino.settings.VersionHistoryBridge
import com.keynumber.folino.ui.theme.FolinoTheme
import com.keynumber.folino.ui.library.FavoritesListScreen
import com.keynumber.folino.ui.library.RecentScreen
import com.keynumber.folino.ui.library.LibraryScreen
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.outlined.History
import com.keynumber.folino.ui.library.PlaylistDetailScreen
import com.keynumber.folino.ui.library.PlaylistsListScreen
import com.keynumber.folino.ui.library.RecentlyDeletedScreen
import com.keynumber.folino.ui.library.TagDetailScreen
import com.keynumber.folino.ui.library.TagsListScreen
import com.keynumber.folino.ui.debug.DebugScreen
import com.keynumber.folino.ui.licenses.LicensesScreen
import com.keynumber.folino.ui.scoreinfo.EditScoreInfoScreen
import com.keynumber.folino.ui.settings.SettingsPrefs
import com.keynumber.folino.ui.settings.SettingsScreen
import com.keynumber.folino.ui.settings.VersionHistoryItem
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.net.URLDecoder
import java.net.URLEncoder

class MainActivity : ComponentActivity(), PipHost {

    companion object {
        /** Extra key used by ShareTargetActivity to request opening a score after import. */
        const val EXTRA_OPEN_SCORE_ID = "open_score_id"
        /** Extra key used by ShareTargetActivity to pass the imported score's display title. */
        const val EXTRA_OPEN_SCORE_TITLE = "open_score_title"
    }

    // Holds a score id delivered via EXTRA_OPEN_SCORE_ID (from ShareTargetActivity). Set on cold
    // start (read from intent in setContent) and on re-delivery (onNewIntent). Consumed once by
    // LibraryNavGraph's LaunchedEffect, then cleared to null so repeat taps don't re-navigate.
    var pendingOpenScoreId: String? by mutableStateOf(null)
    // Companion title for pendingOpenScoreId; may be null/empty if the import result had no title.
    var pendingOpenScoreTitle: String? by mutableStateOf(null)

    private val pipReceiver = PipActionReceiver()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = SettingsPrefs(applicationContext)
        val activity = this@MainActivity

        ContextCompat.registerReceiver(
            this,
            pipReceiver,
            IntentFilter(ReaderPipActions.ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )

        // Re-apply the persisted crash-reporting opt-out before any UI. Synchronous read mirrors the
        // VersionHistory spike pattern below; DataStore is the source of truth (iOS re-applies the
        // UserDefaults flag at bootstrap the same way). Default true = opt-in.
        val crashEnabled = runBlocking { prefs.crashReporting.first() }
        CrashReporting.setCollectionEnabled(crashEnabled)

        // Version History is hidden on the very first Android release (1.0.0): a 1.0.0 user has no prior version,
        // so a "what's new" list has nothing meaningful to show. It appears from the next version onward.
        // TEMPORARY GUARD — remove this `if` (always load) any time after 1.0.0 has shipped.
        val versionItems =
            if (BuildConfig.VERSION_NAME == "1.0.0") {
                emptyList()
            } else {
                // Spike note: synchronous JNI decode on the main thread before setContent. Acceptable for this
                // PoC (one small asset); production should move the asset read + JNI round-trip off the main thread.
                val yml = assets.open("VersionHistory.yml").readBytes()
                VersionHistoryBridge.load(yml)
                    .map { VersionHistoryItem(it.version, it.descriptions) }
            }

        // Seed pending open from a cold-start EXTRA_OPEN_SCORE_ID (ShareTargetActivity → MainActivity).
        intent?.getStringExtra(EXTRA_OPEN_SCORE_ID)?.let { id ->
            intent.removeExtra(EXTRA_OPEN_SCORE_ID)
            pendingOpenScoreId = id
            pendingOpenScoreTitle = intent.getStringExtra(EXTRA_OPEN_SCORE_TITLE)
            intent.removeExtra(EXTRA_OPEN_SCORE_TITLE)
        }

        setContent {
            FolinoTheme {
                Surface {
                    // Keep PiP params current: auto-enter flag (API 31+) and play/pause glyph.
                    val pipEligible by ReaderPipController.eligible.collectAsState()
                    val pipPlaying by ReaderPipController.isPlaying.collectAsState()
                    val pipAspect by ReaderPipController.contentAspect.collectAsState()
                    LaunchedEffect(pipEligible, pipPlaying, pipAspect) {
                        runCatching {
                            activity.setPictureInPictureParams(
                                buildPipParams(activity, pipAspect, pipPlaying, autoEnter = pipEligible),
                            )
                        }.onFailure { android.util.Log.w("ReaderPip", "setPictureInPictureParams failed", it) }
                    }
                    // Library is the main screen; Settings opens as a full-screen
                    // destination (Android idiom) reached from a gear icon in the
                    // Library app bar, with a back arrow to return.
                    val rootNav = rememberNavController()
                    NavHost(rootNav, startDestination = "library") {
                        composable("library") {
                            val activity = LocalContext.current as? MainActivity
                            LibraryNavGraph(
                                prefs = prefs,
                                onOpenSettings = { rootNav.navigate("settings") },
                                pendingOpenScoreId = activity?.pendingOpenScoreId,
                                pendingOpenScoreTitle = activity?.pendingOpenScoreTitle,
                                onPendingOpenConsumed = {
                                    activity?.pendingOpenScoreId = null
                                    activity?.pendingOpenScoreTitle = null
                                },
                            )
                        }
                        composable("settings") {
                            SettingsNavGraph(prefs, versionItems, onBack = { rootNav.popBackStackIfResumed() })
                        }
                    }
                }
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // API 31+ auto-enters via setAutoEnterEnabled; older versions enter here when eligible.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && ReaderPipController.eligible.value) {
            runCatching {
                enterPictureInPictureMode(
                    buildPipParams(
                        this,
                        ReaderPipController.contentAspect.value,
                        ReaderPipController.isPlaying.value,
                        autoEnter = false,
                    ),
                )
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        ReaderPipController.setInPipMode(isInPictureInPictureMode)
    }

    override fun enterPipNow() {
        runCatching {
            enterPictureInPictureMode(
                buildPipParams(
                    this,
                    ReaderPipController.contentAspect.value,
                    ReaderPipController.isPlaying.value,
                    autoEnter = false,
                ),
            )
        }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(pipReceiver) }
        super.onDestroy()
    }

    // Called when MainActivity is already running and a second share finishes (singleTask / singleTop).
    // Updates the Compose-observable state so LibraryNavGraph navigates without an Activity recreate.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra(EXTRA_OPEN_SCORE_ID)?.let { id ->
            intent.removeExtra(EXTRA_OPEN_SCORE_ID)
            pendingOpenScoreId = id
            pendingOpenScoreTitle = intent.getStringExtra(EXTRA_OPEN_SCORE_TITLE)
            intent.removeExtra(EXTRA_OPEN_SCORE_TITLE)
        }
    }
}

@Composable
private fun LibraryNavGraph(
    prefs: SettingsPrefs,
    onOpenSettings: () -> Unit,
    pendingOpenScoreId: String? = null,
    pendingOpenScoreTitle: String? = null,
    onPendingOpenConsumed: () -> Unit = {},
) {
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
        currentRoute == "playlists" || currentRoute == "tags" || currentRoute == "favorites" ||
        currentRoute == "recent"

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
        vm.markOpened(row.id)
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
                    icon = { Icon(Icons.Outlined.History, contentDescription = null) },
                    label = { Text(stringResource(R.string.nav_recent)) },
                    selected = currentRoute == "recent",
                    onClick = { switchTo("recent") },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
                NavigationDrawerItem(
                    icon = { Icon(Icons.Filled.Star, contentDescription = null) },
                    label = { Text(stringResource(R.string.nav_favorites)) },
                    selected = currentRoute == "favorites",
                    onClick = { switchTo("favorites") },
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
                // Debug-only entry to the Crashlytics test menu. Compiled out of release builds.
                if (BuildConfig.DEBUG) {
                    NavigationDrawerItem(
                        icon = { Icon(Icons.Filled.BugReport, contentDescription = null) },
                        label = { Text("Debug menu") },
                        selected = currentRoute == "debug",
                        onClick = {
                            scope.launch { drawerState.close() }
                            nav.navigate("debug")
                        },
                        modifier = Modifier.padding(horizontal = 12.dp),
                    )
                }
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
                    onEditInfoForScore = { id -> nav.navigate("editInfo/$id") },
                )
            }
            composable("recent") {
                RecentScreen(
                    viewModel = vm,
                    onOpenScore = openReader,
                    onOpenDrawer = openDrawer,
                )
            }
            composable("favorites") {
                FavoritesListScreen(
                    viewModel = vm,
                    onOpenScore = openReader,
                    onOpenDrawer = openDrawer,
                    onEditInfoForScore = { id -> nav.navigate("editInfo/$id") },
                )
            }
            composable("debug") {
                DebugRoute(onBack = { nav.popBackStackIfResumed() })
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
                    onBack = { nav.popBackStackIfResumed() },
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
                    onBack = { nav.popBackStackIfResumed() },
                )
            }
            composable(
                "editInfo/{id}",
                arguments = listOf(navArgument("id") { type = NavType.StringType }),
            ) { entry ->
                val id = entry.arguments?.getString("id") ?: ""
                EditScoreInfoScreen(
                    load = { vm.scoreInfoForEditing(id) },
                    onSave = { f ->
                        vm.saveScoreInfo(id, f.title, f.subtitle, f.composer, f.arranger, f.lyricist, f.copyright)
                    },
                    onClose = { nav.popBackStackIfResumed() },
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
                // Reader display mode comes from the Settings → Layout pref (DataStore). Default
                // "page" matches SettingsPrefs; until the page/horizontal surfaces land, those
                // modes fall back to vertical scroll inside ReaderScreen.
                val layoutPref by prefs.layoutMode.collectAsState(initial = "page")
                val staffSize by prefs.staffSize.collectAsState(initial = 28.0)
                val honorBreaks by prefs.honorBreaks.collectAsState(initial = true)
                val collapseRests by prefs.collapseRests.collectAsState(initial = false)
                val showInvisible by prefs.showInvisible.collectAsState(initial = false)
                val hiddenStaves by prefs.hiddenStaves.collectAsState(initial = emptySet())
                val clefOverrides by prefs.clefOverrides.collectAsState(initial = emptySet())
                val hintDismissed by prefs.pageTapHintDismissed.collectAsState(initial = false)
                val globalA4Hz by prefs.a4ReferenceHz.collectAsState(initial = 440.0)
                val pipEnabled by prefs.pip.collectAsState(initial = false)
                val showSeekBar by prefs.showSeekBar.collectAsState(initial = true)
                val scope = rememberCoroutineScope()
                val context = LocalContext.current
                // Per-score A–B range persistence (Room). Global repeat mode lives in DataStore (prefs).
                val abRepeatStore = remember(context) { com.keynumber.folino.library.RoomLibraryStore(context) }
                // Per-score Reader preferences (display + playback + mixer). The generated bridge view
                // model wraps the Swift ReaderPreferencesBridge over the same Room store; it is scoped
                // to this Reader route and opened once per score id. The app module owns this wiring so
                // the Reader Compose module never depends on :FolinoLibraryAndroid (mirrors how the
                // AB-repeat + display-options lambdas are injected from here).
                val prefsVm: ReaderPreferencesBridgeViewModel =
                    viewModel(
                        key = "readerPrefs/$id",
                        factory = ReaderPreferencesController.factory(context.applicationContext),
                    )
                LaunchedEffect(id) { prefsVm.open(id, defaultStaffSize = staffSize) }
                val prefsState by prefsVm.state.collectAsState()
                val displayOptions = layoutOptionsFromPrefs(
                    layoutPref, staffSize, honorBreaks, collapseRests, showInvisible, hiddenStaves, clefOverrides,
                )
                ReaderScreen(
                    scoreId = id,
                    title = title,
                    onEditInfo = { nav.navigate("editInfo/$id") },
                    layoutMode = ReaderLayoutMode.fromPref(layoutPref),
                    displayOptions = displayOptions,
                    onDisplayOptionsChange = { o ->
                        scope.launch {
                            prefs.setLayoutMode(o.mode.toPref())
                            prefs.setStaffSize(o.staffSize)
                            prefs.setHonorBreaks(o.honorLayoutBreaks)
                            prefs.setCollapseRests(o.collapseMultiMeasureRests)
                            prefs.setShowInvisible(o.showInvisibleElements)
                            prefs.setHiddenStaves(o.hiddenStavesPref())
                            prefs.setClefOverrides(o.clefOverridesPref())
                        }
                    },
                    pageTapHintDismissed = hintDismissed,
                    onDismissPageTapHint = { scope.launch { prefs.setPageTapHintDismissed() } },
                    globalA4ReferenceHz = globalA4Hz,
                    pipEnabled = pipEnabled,
                    showSeekBar = showSeekBar,
                    onShowSeekBarChange = { v -> scope.launch { prefs.setShowSeekBar(v) } },
                    initialRepeatModeLoader = { RepeatMode.fromWire(prefs.repeatMode.first()) },
                    loadAbRange = {
                        abRepeatStore.loadAbRepeat(id)?.let { AbRepeatRange(it.first, it.second) }
                    },
                    persistAbRange = { r ->
                        abRepeatStore.saveAbRepeat(id, r?.let { it.startMeasure to it.endMeasure })
                    },
                    persistRepeatMode = { m -> scope.launch { prefs.setRepeatMode(m.wire) } },
                    onBack = { nav.popBackStackIfResumed() },
                )
            }
        }
        // Navigate to a just-imported score when ShareTargetActivity delivers a score id. The key
        // is the id itself so that a new share while already in the reader re-triggers navigation.
        LaunchedEffect(pendingOpenScoreId) {
            pendingOpenScoreId?.let { id ->
                onPendingOpenConsumed()
                val t = URLEncoder.encode(pendingOpenScoreTitle.orEmpty(), "UTF-8")
                nav.navigate("reader/$id/$t")
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
            LicensesRoute(onBack = { nav.popBackStackIfResumed() })
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

internal class LibraryVMFactory(private val context: android.content.Context) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T =
        LibraryAndroidStoreViewModel.create(
            store = com.keynumber.folino.library.RoomLibraryStore(context),
            pdfRenderer = com.keynumber.folino.export.PdfScoreRenderer(context),
            audioExporter = com.keynumber.folino.export.AudioScoreExporter(context),
        ) as T
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DebugRoute(onBack: () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Debug menu") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding)) { DebugScreen() }
    }
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

// Pops the back stack only while the current destination is still RESUMED. A rapid double-tap on a
// back button would otherwise call popBackStack() twice: the first pop returns to the start
// destination and the second pops past it, leaving an empty NavHost (a blank screen). The leaving
// destination drops out of RESUMED the instant the first pop begins, so the second tap is a no-op.
private fun NavController.popBackStackIfResumed() {
    if (currentBackStackEntry?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED) == true) {
        popBackStack()
    }
}
