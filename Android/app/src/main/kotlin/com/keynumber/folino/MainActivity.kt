package com.keynumber.folino

import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalNavigationDrawer
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
import androidx.compose.runtime.saveable.rememberSaveable
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
import com.keynumber.folino.export.ScoreShareLauncher
import com.keynumber.folino.library.ReaderPreferencesController
import com.keynumber.folino.library.ScoreExportFormatWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import com.keynumber.folino.library.generated.ReaderPreferencesBridgeViewModel
import androidx.core.content.ContextCompat
import com.keynumber.folino.reader.PipHost
import com.keynumber.folino.reader.AbRepeatRange
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.RepeatMode
import com.keynumber.folino.reader.ReaderLayoutMode
import com.keynumber.folino.reader.StaffAddress as ReaderStaffAddress
import com.keynumber.folino.reader.ReaderPipController
import com.keynumber.folino.reader.PlaylistContinuationMode
import com.keynumber.folino.reader.ReaderScreen
import com.keynumber.folino.reader.toPref
import com.keynumber.folino.diagnostics.AndroidAnalytics
import com.keynumber.folino.diagnostics.CrashReporting
import com.keynumber.folino.settings.VersionHistoryBridge
import com.keynumber.folino.ui.theme.FolinoTheme
import com.keynumber.folino.ui.library.ExportFormatSheet
import com.keynumber.folino.ui.library.FavoritesListScreen
import com.keynumber.folino.ui.library.LibraryDrawerContent
import com.keynumber.folino.ui.library.RecentScreen
import com.keynumber.folino.ui.library.LibraryScreen
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
import com.keynumber.folino.ui.settings.VersionHistoryScreen
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
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

        // Same opt-out re-apply for Firebase Analytics. initialize() binds the SDK to the app Context (required
        // before setCollectionEnabled, unlike Crashlytics' no-arg singleton); the persisted flag then gates both
        // the SDK and the local AndroidAnalytics gate. Default true = opt-in, matching iOS bootstrap.
        val analyticsEnabled = runBlocking { prefs.analytics.first() }
        AndroidAnalytics.initialize(applicationContext)
        AndroidAnalytics.setCollectionEnabled(analyticsEnabled)

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
                                onOpenSettings = {
                                    // Task 18 smoke event: fire settings_opened through the REAL pipeline
                                    // (Swift builder → AndroidAnalytics.log) at the single Settings entry point,
                                    // mirroring iOS which logs it once at the settings button. Once per open; the
                                    // drawer's gear is the only nav action to "settings", so no duplicate.
                                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingsOpened())
                                    // screen_view for settings (its own rootNav destination; single entry point here,
                                    // mirroring iOS SettingsSheet.onAppear → .settings).
                                    AndroidAnalytics.log(AndroidAnalytics.bridge.screen("settings"))
                                    rootNav.navigate("settings")
                                },
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

    // Launch analytics (events-first; replaces the old user-property push). The store hydrates synchronously in its
    // init, so emit the library_snapshot + settings_snapshot events once here, mirroring iOS AppBootstrap. Re-emitting
    // after import/delete is a deferred minor (iOS emits once at launch too).
    LaunchedEffect(Unit) {
        AndroidAnalytics.log(vm.librarySnapshot())
        AndroidAnalytics.log(
            AndroidAnalytics.bridge.settingsSnapshot(
                metronome = prefs.metronome.first(),
                pictureInPicture = prefs.pip.first(),
                collapseMultiMeasureRests = prefs.collapseRests.first(),
                showInvisibles = prefs.showInvisible.first(),
                keepScreenAwake = prefs.keepAwake.first(),
                showSeekBar = prefs.showSeekBar.first(),
                repeatMode = prefs.repeatMode.first(),
                playlistContinuation = prefs.playlistContinuationMode.first(),
                a4ReferenceHz = prefs.a4ReferenceHz.first(),
                layoutMode = prefs.layoutMode.first(),
                crashReportingEnabled = prefs.crashReporting.first(),
                // soundfont_preset: the live downloaded tier lives in a separate JNI module; report the bundled default.
                soundfontPreset = "lightweight",
            ),
        )
    }

    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val currentRoute = nav.currentBackStackEntryAsState().value?.destination?.route

    // Reader is a detail pushed on top; only the top-level list destinations
    // expose the drawer (hamburger + edge swipe).
    val drawerCapable = currentRoute == "list" || currentRoute == "recentlyDeleted" ||
        currentRoute == "playlists" || currentRoute == "tags" || currentRoute == "favorites" ||
        currentRoute == "recent"

    // The drawer belongs to the list-level destinations only; a non-capable route (the Reader, the
    // detail screens) must never show it. Disabling gestures stops the *user* from opening it, but the
    // drawer can still settle Open on its own when the window is resized: entering / leaving PiP resizes
    // the Activity, and Material3's ModalNavigationDrawer re-anchors its internal draggable on a size
    // change and can land on the Open anchor. Force it closed whenever it is open on a non-capable
    // route so returning from PiP never strands the Library drawer over the Reader.
    LaunchedEffect(drawerCapable, drawerState.isOpen) {
        if (!drawerCapable && drawerState.isOpen) drawerState.close()
    }

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
            LibraryDrawerContent(
                currentRoute = currentRoute,
                onNavigate = { switchTo(it) },
                onOpenSettings = {
                    scope.launch { drawerState.close() }
                    onOpenSettings()
                },
                onOpenDebug = {
                    scope.launch { drawerState.close() }
                    nav.navigate("debug")
                },
            )
        },
    ) {
        val openDrawer: () -> Unit = { scope.launch { drawerState.open() } }
        NavHost(nav, startDestination = "list") {
            composable("list") {
                ScreenViewEffect("library")
                LibraryScreen(
                    viewModel = vm,
                    onOpenScore = openReader,
                    onOpenDrawer = openDrawer,
                    onEditInfoForScore = { id -> nav.navigate("editInfo/$id") },
                )
            }
            composable("recent") {
                ScreenViewEffect("library")
                RecentScreen(
                    viewModel = vm,
                    onOpenScore = openReader,
                    onOpenDrawer = openDrawer,
                )
            }
            composable("favorites") {
                ScreenViewEffect("library")
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
                ScreenViewEffect("recentlyDeleted")
                RecentlyDeletedScreen(
                    viewModel = vm,
                    onOpenScore = openReader,
                    onOpenDrawer = openDrawer,
                )
            }
            composable("playlists") {
                ScreenViewEffect("library")
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
                ScreenViewEffect("playlistDetail")
                PlaylistDetailScreen(
                    viewModel = vm,
                    playlistId = id,
                    playlistName = name,
                    onOpenScore = { row ->
                        vm.markOpened(row.id)
                        val t = URLEncoder.encode(row.title, "UTF-8")
                        nav.navigate("reader/${row.id}/$t?playlistId=$id")
                    },
                    onBack = { nav.popBackStackIfResumed() },
                )
            }
            composable("tags") {
                ScreenViewEffect("library")
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
                ScreenViewEffect("tagDetail")
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
                ScreenViewEffect("scoreInfo")
                EditScoreInfoScreen(
                    load = { vm.scoreInfoForEditing(id) },
                    onSave = { f ->
                        vm.saveScoreInfo(id, f.title, f.subtitle, f.composer, f.arranger, f.lyricist, f.copyright)
                    },
                    onClose = { nav.popBackStackIfResumed() },
                )
            }
            composable(
                "reader/{id}/{title}?playlistId={playlistId}",
                arguments = listOf(
                    navArgument("id") { type = NavType.StringType },
                    navArgument("title") { type = NavType.StringType },
                    navArgument("playlistId") {
                        type = NavType.StringType
                        nullable = true
                        defaultValue = null
                    },
                ),
            ) { entry ->
                val navId = entry.arguments?.getString("id") ?: ""
                val title = URLDecoder.decode(entry.arguments?.getString("title") ?: "", "UTF-8")
                val playlistId = entry.arguments?.getString("playlistId")
                // In-place retarget anchor: seeded from the nav arg, advanced by the Reader's auto-advance.
                // Keyed on navId so opening a different score from the library resets it.
                var currentScoreId by rememberSaveable(navId) { mutableStateOf(navId) }
                // Reader display mode comes from the Settings → Layout pref (DataStore). Default
                // "page" matches SettingsPrefs; until the page/horizontal surfaces land, those
                // modes fall back to vertical scroll inside ReaderScreen.
                //
                // Display settings split across two stores: mode / collapse-rests / show-invisible stay
                // GLOBAL (DataStore, shared across scores); staff size / honor-breaks / hidden-staves /
                // clef-overrides are PER-SCORE (the ReaderPreferences bridge below). The score-specific
                // half is read from the bridge, not from these global flows.
                val layoutPref by prefs.layoutMode.collectAsState(initial = "page")
                val staffSize by prefs.staffSize.collectAsState(initial = 28.0)
                val collapseRests by prefs.collapseRests.collectAsState(initial = false)
                val showInvisible by prefs.showInvisible.collectAsState(initial = false)
                val hintDismissed by prefs.pageTapHintDismissed.collectAsState(initial = false)
                val globalA4Hz by prefs.a4ReferenceHz.collectAsState(initial = 440.0)
                val metronomeEnabled by prefs.metronome.collectAsState(initial = false)
                val pipEnabled by prefs.pip.collectAsState(initial = false)
                val keepScreenAwake by prefs.keepAwake.collectAsState(initial = true)
                val showSeekBar by prefs.showSeekBar.collectAsState(initial = true)
                val autoFollowEnabled by prefs.autoFollow.collectAsState(initial = true)
                val continuationModeWire by prefs.playlistContinuationMode.collectAsState(initial = "playThrough")
                val scope = rememberCoroutineScope()
                val context = LocalContext.current
                // Per-score A–B range persistence (Room). Global repeat mode lives in DataStore (prefs).
                val abRepeatStore = remember(context) { com.keynumber.folino.library.RoomLibraryStore(context) }
                // Share: the format picker → export → system share-sheet flow for this score, owned by
                // the app module (mirrors the Library's export→share path). The Reader module only
                // triggers it via [onShare]; the export VM and FileProvider wiring live here.
                var shareFormats by remember { mutableStateOf<List<ScoreExportFormatWire>>(emptyList()) }
                var showShareSheet by remember { mutableStateOf(false) }
                val exportFailedMsg = stringResource(R.string.export_failed)
                // Per-score Reader preferences (display + playback + mixer). The generated bridge view
                // model wraps the Swift ReaderPreferencesBridge over the same Room store; it is scoped
                // to this Reader route and opened once per score id. The app module owns this wiring so
                // the Reader Compose module never depends on :FolinoLibraryAndroid (mirrors how the
                // AB-repeat + display-options lambdas are injected from here).
                val prefsVm: ReaderPreferencesBridgeViewModel =
                    viewModel(
                        key = "readerPrefs/$currentScoreId",
                        factory = ReaderPreferencesController.factory(context.applicationContext),
                    )
                LaunchedEffect(currentScoreId) { prefsVm.open(currentScoreId, defaultStaffSize = staffSize) }
                val prefsState by prefsVm.state.collectAsState()
                // Per-score staff visibility + clef overrides come from the bridge's imperative getters.
                // Re-read them whenever the bridge state ticks (every per-staff mutation publishes a new
                // state), so the inspector list refreshes after a hide/show or clef change.
                val perScoreHidden = remember(prefsState) {
                    prefsVm.hiddenStaves()
                        .map { ReaderStaffAddress(it.partIndex, it.staffIndexInPart) }
                        .toSet()
                }
                val perScoreClefs = remember(prefsState) {
                    prefsVm.clefOverrides()
                        .associate { ReaderStaffAddress(it.partIndex, it.staffIndexInPart) to it.rawType }
                }
                // Compose the display snapshot from both stores: global mode / collapse / show-invisible,
                // per-score staff size / honor-breaks / hidden / clef.
                val displayOptions = LayoutOptions(
                    mode = ReaderLayoutMode.fromPref(layoutPref),
                    staffSize = prefsState.staffSize,
                    honorLayoutBreaks = prefsState.honorLayoutBreaks,
                    collapseMultiMeasureRests = collapseRests,
                    showInvisibleElements = showInvisible,
                    hiddenStaves = perScoreHidden,
                    clefOverrides = perScoreClefs,
                )
                // Analytics baselines: the last persisted tempo / transpose, so the inspector's persist callbacks can
                // log a direction (increase/decrease, up/down) on each committed change. Re-seeded per score.
                var lastTempoForAnalytics by remember(currentScoreId) {
                    mutableStateOf(if (prefsState.tempoMultiplier == 0.0) 1.0 else prefsState.tempoMultiplier)
                }
                var lastTransposeForAnalytics by remember(currentScoreId) {
                    mutableStateOf(prefsState.transposeSemitones)
                }
                ScreenViewEffect("reader")
                ReaderScreen(
                    scoreId = currentScoreId,
                    title = title,
                    onEditInfo = {
                        AndroidAnalytics.log(AndroidAnalytics.bridge.scoreInfoOpened("readerOverlay"))
                        nav.navigate("editInfo/$currentScoreId")
                    },
                    onShare = {
                        scope.launch {
                            shareFormats = withContext(Dispatchers.Default) { vm.exportFormats(currentScoreId) }
                            showShareSheet = true
                        }
                    },
                    layoutMode = ReaderLayoutMode.fromPref(layoutPref),
                    displayOptions = displayOptions,
                    onDisplayOptionsChange = { o ->
                        // Reader-initiated layout switch (display-options inspector). Distinct event from the Settings
                        // `setting_changed` layout_mode key, mirroring iOS layout_mode_changed.
                        if (o.mode != displayOptions.mode) {
                            AndroidAnalytics.log(AndroidAnalytics.bridge.layoutModeChanged(o.mode.toPref()))
                        }
                        // Global half → DataStore.
                        scope.launch {
                            prefs.setLayoutMode(o.mode.toPref())
                            prefs.setCollapseRests(o.collapseMultiMeasureRests)
                            prefs.setShowInvisible(o.showInvisibleElements)
                        }
                        // Per-score half → ReaderPreferences bridge. Diff against the current snapshot so
                        // the whole-options `onChange` contract maps onto the bridge's scalar / per-staff
                        // mutators. Staff size / honor are scalars; hidden / clef are per-staff deltas.
                        if (o.staffSize != displayOptions.staffSize) prefsVm.setStaffSize(o.staffSize)
                        if (o.honorLayoutBreaks != displayOptions.honorLayoutBreaks) {
                            prefsVm.setHonorLayoutBreaks(o.honorLayoutBreaks)
                        }
                        (o.hiddenStaves - displayOptions.hiddenStaves).forEach {
                            prefsVm.setStaffHidden(it.partIndex, it.staffIndexInPart, hidden = true)
                        }
                        (displayOptions.hiddenStaves - o.hiddenStaves).forEach {
                            prefsVm.setStaffHidden(it.partIndex, it.staffIndexInPart, hidden = false)
                        }
                        o.clefOverrides.forEach { (addr, raw) ->
                            if (displayOptions.clefOverrides[addr] != raw) {
                                prefsVm.setClef(addr.partIndex, addr.staffIndexInPart, raw)
                            }
                        }
                        (displayOptions.clefOverrides.keys - o.clefOverrides.keys).forEach { addr ->
                            // A removed clef override = reset to the staff's authored/default clef. The
                            // bridge has no "clear" verb; an empty rawType is the reset sentinel (matches
                            // the reducer's treatment of "" as no override).
                            prefsVm.setClef(addr.partIndex, addr.staffIndexInPart, "")
                        }
                    },
                    pageTapHintDismissed = hintDismissed,
                    onDismissPageTapHint = { scope.launch { prefs.setPageTapHintDismissed() } },
                    globalA4ReferenceHz = globalA4Hz,
                    // Per-score playback scalars seeded from the bridge. tempoMultiplier == 0.0 ("none")
                    // and a4ReferenceHz == 0.0 ("inherit") are sentinels resolved to the engine default
                    // rate (1.0) and the global SettingsPrefs A4 respectively.
                    initialMasterVolume = prefsState.masterVolume.toFloat(),
                    initialTempoMultiplier =
                        (if (prefsState.tempoMultiplier == 0.0) 1.0 else prefsState.tempoMultiplier).toFloat(),
                    initialA4ReferenceHz =
                        if (prefsState.a4ReferenceHz == 0.0) globalA4Hz else prefsState.a4ReferenceHz,
                    persistMasterVolume = { v -> prefsVm.setMasterVolume(v) },
                    persistTempoMultiplier = { v ->
                        if (v > lastTempoForAnalytics) {
                            AndroidAnalytics.log(AndroidAnalytics.bridge.tempoIncreased())
                        } else if (v < lastTempoForAnalytics) {
                            AndroidAnalytics.log(AndroidAnalytics.bridge.tempoDecreased())
                        }
                        lastTempoForAnalytics = v
                        prefsVm.setTempoMultiplier(v)
                    },
                    persistA4ReferenceHz = { v -> prefsVm.setA4ReferenceHz(v) },
                    // Persist-only: the transpose audio/notation effect is not implemented on Android yet;
                    // the inspector stepper only stores this value through the ReaderPreferences bridge.
                    transposeSemitones = prefsState.transposeSemitones,
                    persistTranspose = { v ->
                        if (v > lastTransposeForAnalytics) {
                            AndroidAnalytics.log(AndroidAnalytics.bridge.transposeUp())
                        } else if (v < lastTransposeForAnalytics) {
                            AndroidAnalytics.log(AndroidAnalytics.bridge.transposeDown())
                        }
                        lastTransposeForAnalytics = v
                        prefsVm.setTranspose(v)
                    },
                    metronomeEnabled = metronomeEnabled,
                    onMetronomeChange = { v -> scope.launch { prefs.setMetronome(v) } },
                    // Per-score mixer overrides: the bridge stores them by positional StaffAddress; the
                    // Reader resolves address↔flat-staffIndex via its parts map for replay + persistence.
                    mixerProgramOverrides = {
                        prefsVm.programOverrides().map {
                            ReaderStaffAddress(it.partIndex, it.staffIndexInPart) to it.program
                        }
                    },
                    mixerVolumeOverrides = {
                        prefsVm.volumeOverrides().map {
                            ReaderStaffAddress(it.partIndex, it.staffIndexInPart) to it.volume.toFloat()
                        }
                    },
                    persistStaffProgram = { addr, program ->
                        prefsVm.setStaffProgram(addr.partIndex, addr.staffIndexInPart, program)
                    },
                    persistStaffVolume = { addr, volume ->
                        prefsVm.setStaffVolume(addr.partIndex, addr.staffIndexInPart, volume.toDouble())
                    },
                    pipEnabled = pipEnabled,
                    keepScreenAwake = keepScreenAwake,
                    showSeekBar = showSeekBar,
                    onShowSeekBarChange = { v -> scope.launch { prefs.setShowSeekBar(v) } },
                    autoFollowEnabled = autoFollowEnabled,
                    onAutoFollowChange = { v ->
                        AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("autoFollow", v))
                        scope.launch { prefs.setAutoFollow(v) }
                    },
                    initialRepeatModeLoader = { RepeatMode.fromWire(prefs.repeatMode.first()) },
                    loadAbRange = {
                        abRepeatStore.loadAbRepeat(currentScoreId)?.let { AbRepeatRange(it.first, it.second) }
                    },
                    persistAbRange = { r ->
                        abRepeatStore.saveAbRepeat(currentScoreId, r?.let { it.startMeasure to it.endMeasure })
                    },
                    persistRepeatMode = { m ->
                        // Reader-initiated repeat-mode change (inspector). Distinct from the Settings repeat_mode key.
                        AndroidAnalytics.log(AndroidAnalytics.bridge.repeatModeChanged(m.wire))
                        scope.launch { prefs.setRepeatMode(m.wire) }
                    },
                    // Playlist provenance (the route's optional playlistId) drives both the auto-advance
                    // logic and the inspector's continuation row (isInPlaylist is derived from playlistId
                    // inside ReaderScreen). The continuation-mode wire value is shown in the inspector;
                    // the auto-advance handler re-reads it fresh from DataStore at each end-of-score.
                    playlistId = playlistId,
                    playlistQueueProvider = {
                        playlistId?.let {
                            withContext(Dispatchers.IO) { abRepeatStore.orderedLivePlaylistScoreIds(it) }
                        } ?: emptyList()
                    },
                    continuationModeProvider = {
                        PlaylistContinuationMode.fromWire(prefs.playlistContinuationMode.first())
                    },
                    onRetargetScore = { next -> currentScoreId = next },
                    continuationModeWire = continuationModeWire,
                    onContinuationModeChange = { v -> scope.launch { prefs.setPlaylistContinuationMode(v) } },
                    // Playback analytics (the Reader module can't import the analytics library, so it raises these
                    // semantic callbacks and the app maps them to the shared catalog). `from` is best-effort, mirroring
                    // iOS: playlist if opened from a playlist, else library_all.
                    onAnalyticsPlaybackStarted = {
                        AndroidAnalytics.log(
                            AndroidAnalytics.bridge.playbackStarted(
                                displayOptions.mode.toPref(),
                                if (playlistId != null) "playlist" else "libraryAll",
                            ),
                        )
                    },
                    onAnalyticsPlaybackPaused = { AndroidAnalytics.log(AndroidAnalytics.bridge.playbackPaused()) },
                    onAnalyticsPlaybackCompleted = {
                        AndroidAnalytics.log(AndroidAnalytics.bridge.playbackCompleted())
                    },
                    onAnalyticsTransportPrevious = {
                        AndroidAnalytics.log(AndroidAnalytics.bridge.transportPrevious())
                    },
                    onAnalyticsTransportNext = { AndroidAnalytics.log(AndroidAnalytics.bridge.transportNext()) },
                    onAnalyticsSeek = { AndroidAnalytics.log(AndroidAnalytics.bridge.seek()) },
                    onBack = { nav.popBackStackIfResumed() },
                )
                if (showShareSheet) {
                    ExportFormatSheet(
                        formats = shareFormats,
                        onPick = { token ->
                            showShareSheet = false
                            scope.launch {
                                val dir = ScoreShareLauncher.exportsDir(context).absolutePath
                                val path = withContext(Dispatchers.Default) { vm.exportScore(currentScoreId, token, dir) }
                                if (path.isEmpty()) {
                                    Toast.makeText(context, exportFailedMsg, Toast.LENGTH_SHORT).show()
                                } else {
                                    ScoreShareLauncher.share(context, listOf(path))
                                    // Reader share (iOS parity: readerOverlay / single). `token` is the export-format
                                    // token; the bridge maps it to the share method's wire value.
                                    AndroidAnalytics.log(
                                        AndroidAnalytics.bridge.share(token, "readerOverlay", "single"),
                                    )
                                }
                            }
                        },
                        onDismiss = { showShareSheet = false },
                    )
                }
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
                onOpenVersionHistory = { nav.navigate("versionHistory") },
            )
        }
        composable("licenses") {
            LicensesRoute(onBack = { nav.popBackStackIfResumed() })
        }
        composable("versionHistory") {
            VersionHistoryRoute(
                versionItems = versionItems,
                onBack = { nav.popBackStackIfResumed() },
            )
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
    onOpenVersionHistory: () -> Unit,
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
            SettingsScreen(prefs, versionItems, onOpenLicenses = onOpenLicenses, onOpenVersionHistory = onOpenVersionHistory)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VersionHistoryRoute(
    versionItems: List<VersionHistoryItem>,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_version_history)) },
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
        Box(Modifier.padding(padding)) { VersionHistoryScreen(versionItems) }
    }
}

/**
 * Manual `screen_view` for a top-level Compose destination, mirroring iOS `.onAppear { logScreen(...) }`. Fires once
 * when the destination enters composition (Compose is a single Activity, so per-screen views are not auto-collected).
 * [token] is an `AnalyticsScreen` case-name token; the bridge maps it to the wire `screen_name`. Library browsing
 * destinations (all / favorites / recent / playlists / tags) all pass "library", matching iOS where they are one
 * segmented `LibraryRootScreen`.
 */
@Composable
private fun ScreenViewEffect(token: String) {
    LaunchedEffect(Unit) {
        AndroidAnalytics.log(AndroidAnalytics.bridge.screen(token))
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
