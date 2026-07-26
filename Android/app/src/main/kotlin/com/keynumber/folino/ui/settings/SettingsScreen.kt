package com.keynumber.folino.ui.settings

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForwardIos
import androidx.compose.material.icons.automirrored.filled.PlaylistPlay
import androidx.compose.material.icons.filled.Analytics
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.PictureInPicture
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.ScreenLockPortrait
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.UnfoldLess
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.filled.ViewArray
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.keynumber.folino.BuildConfig
import com.keynumber.folino.R
import com.keynumber.folino.diagnostics.AndroidAnalytics
import com.keynumber.folino.diagnostics.CrashReporting
import com.keynumber.folino.reader.RepeatMode
import com.keynumber.folino.reader.RepeatModePicker
import com.keynumber.folino.reader.ui.InspectorRow
import com.keynumber.folino.reader.ui.InspectorSectionHeader
import com.keynumber.folino.reader.ui.MetronomeIcon
import com.keynumber.folino.reader.ui.ResettableSlider
import com.keynumber.folino.reader.ui.TuningForkIcon
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(
    prefs: SettingsPrefs,
    versionHistory: List<VersionHistoryItem>,
    onOpenLicenses: (() -> Unit)? = null,
    onOpenVersionHistory: (() -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val metronome by prefs.metronome.collectAsState(initial = false)
    val pip by prefs.pip.collectAsState(initial = false)
    val collapse by prefs.collapseRests.collectAsState(initial = false)
    val keepAwake by prefs.keepAwake.collectAsState(initial = true)
    val precount by prefs.precount.collectAsState(initial = false)
    val layout by prefs.layoutMode.collectAsState(initial = "page")
    val a4Hz by prefs.a4ReferenceHz.collectAsState(initial = 440.0)
    val crashReporting by prefs.crashReporting.collectAsState(initial = true)
    val analyticsEnabled by prefs.analytics.collectAsState(initial = true)
    val repeatModeWire by prefs.repeatMode.collectAsState(initial = "off")
    val continuationModeWire by prefs.playlistContinuationMode.collectAsState(initial = "playThrough")
    val showInvisible by prefs.showInvisible.collectAsState(initial = false)
    val showSeekBar by prefs.showSeekBar.collectAsState(initial = true)
    val autoFollow by prefs.autoFollow.collectAsState(initial = true)
    val pageTurnButtonsVisible by prefs.pageTurnButtonsVisible.collectAsState(initial = true)
    val soundfontVM = remember { com.keynumber.folino.soundfont.SoundfontController.viewModel(context) }
    val sfState by soundfontVM.stateWire.collectAsState()

    // Self-heal: while the bridge reports an in-flight download, periodically re-evaluate from disk. The moment the
    // file is fully written, `startDownloadIfNeeded()` flips the state to `downloaded`, so the UI always converges
    // even if a terminal observable update is ever missed. A no-op while the file is genuinely still downloading.
    LaunchedEffect(sfState.statusRaw) {
        if (sfState.statusRaw == "downloading") {
            while (true) {
                kotlinx.coroutines.delay(1500)
                soundfontVM.startDownloadIfNeeded()
            }
        }
    }

    LazyColumn(
        Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // ── Reader ────────────────────────────────────────────────────────────
        item { InspectorSectionHeader(stringResource(R.string.settings_section_reader)) }
        item {
            ToggleRow(
                icon = MetronomeIcon,
                title = stringResource(R.string.settings_reader_metronome),
                checked = metronome,
                onChange = { v ->
                    scope.launch { prefs.setMetronome(v) }
                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("metronome", v))
                },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.Timer,
                title = stringResource(R.string.settings_reader_precount),
                checked = precount,
                onChange = { v ->
                    scope.launch { prefs.setPrecount(v) }
                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("precount", v))
                },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.PictureInPicture,
                title = stringResource(R.string.settings_reader_pip),
                checked = pip,
                subtitle = stringResource(R.string.settings_reader_pip_footer),
                onChange = { v ->
                    scope.launch { prefs.setPip(v) }
                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("pictureInPicture", v))
                },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.UnfoldLess,
                title = stringResource(R.string.settings_reader_collapse_rests),
                checked = collapse,
                onChange = { v ->
                    scope.launch { prefs.setCollapseRests(v) }
                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("collapseMultiMeasureRests", v))
                },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.Visibility,
                title = stringResource(R.string.settings_reader_show_invisible),
                checked = showInvisible,
                onChange = { v ->
                    scope.launch { prefs.setShowInvisible(v) }
                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("showInvisibleElements", v))
                },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.ScreenLockPortrait,
                title = stringResource(R.string.settings_reader_keep_awake),
                checked = keepAwake,
                subtitle = stringResource(R.string.settings_reader_keep_awake_footer),
                onChange = { v ->
                    scope.launch { prefs.setKeepAwake(v) }
                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("keepScreenAwake", v))
                },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.Timeline,
                title = stringResource(R.string.settings_reader_show_seek_bar),
                checked = showSeekBar,
                onChange = { v ->
                    scope.launch { prefs.setShowSeekBar(v) }
                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("showSeekBar", v))
                },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.MyLocation,
                title = stringResource(R.string.settings_reader_auto_follow),
                checked = autoFollow,
                onChange = { v ->
                    scope.launch { prefs.setAutoFollow(v) }
                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("autoFollow", v))
                },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.TouchApp,
                title = stringResource(R.string.settings_reader_page_turn_buttons),
                checked = pageTurnButtonsVisible,
                subtitle = stringResource(R.string.settings_reader_page_turn_buttons_footer),
                onChange = { v ->
                    scope.launch { prefs.setPageTurnButtonsVisible(v) }
                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("pageTurnButtons", v))
                },
            )
        }
        item {
            // Repeat mode picker row
            InspectorRow(label = stringResource(R.string.settings_reader_repeat), leadingIcon = Icons.Filled.Repeat) {
                RepeatModePicker(
                    selected = RepeatMode.fromWire(repeatModeWire),
                    enabled = true,
                    onSelect = {
                        // Gate on an actual change (iOS logs via .onChange): re-selecting the current mode emits nothing.
                        if (it.wire != repeatModeWire) {
                            AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedRepeatMode(it.wire))
                        }
                        scope.launch { prefs.setRepeatMode(it.wire) }
                    },
                )
            }
        }
        item {
            // Global sticky playlist-continuation mode. Persist-only: the playlist continuous-playback
            // feature that consumes this value is not yet built on Android, so selecting only saves the
            // choice (no playback behavior is wired). Mirrors the iOS Settings continuation row wording.
            InspectorRow(
                label = stringResource(R.string.settings_playlist_continuation),
                leadingIcon = Icons.AutoMirrored.Filled.PlaylistPlay,
            ) {
                val continuationModes = listOf(
                    "off" to stringResource(R.string.playlist_continuation_off),
                    "playThrough" to stringResource(R.string.playlist_continuation_play_through),
                    "loopPlaylist" to stringResource(R.string.playlist_continuation_loop),
                )
                var expanded by remember { mutableStateOf(false) }
                val current = continuationModes.firstOrNull { it.first == continuationModeWire }
                    ?: continuationModes[1]
                Box {
                    Row(
                        Modifier.clickable { expanded = true }
                            .padding(horizontal = 4.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(current.second)
                        Icon(Icons.Filled.UnfoldMore, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                        continuationModes.forEach { (raw, label) ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                trailingIcon = if (raw == continuationModeWire) {
                                    { Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp)) }
                                } else {
                                    null
                                },
                                onClick = {
                                    if (raw != continuationModeWire) {
                                        AndroidAnalytics.log(
                                            AndroidAnalytics.bridge.settingChangedPlaylistContinuation(raw),
                                        )
                                    }
                                    scope.launch { prefs.setPlaylistContinuationMode(raw) }
                                    expanded = false
                                },
                            )
                        }
                    }
                }
            }
        }
        item {
            // Last A4 value we logged, so a touch-release with no net move (or a reset when already 440) emits no
            // `setting_changed` — mirroring iOS .onChange(of: globalA4Hz), which only fires on an actual change.
            var lastLoggedA4Hz by remember { mutableStateOf(a4Hz) }
            A4SliderRow(
                hz = a4Hz,
                onValueChange = { scope.launch { prefs.setA4ReferenceHz(it.toDouble()) } },
                onValueChangeFinished = {
                    val snapped = when {
                        kotlin.math.abs(a4Hz - 432.0) <= 1.0 -> 432.0
                        kotlin.math.abs(a4Hz - 440.0) <= 1.0 -> 440.0
                        else -> a4Hz
                    }
                    if (snapped != a4Hz) scope.launch { prefs.setA4ReferenceHz(snapped) }
                    if (snapped != lastLoggedA4Hz) {
                        AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedA4(snapped))
                        lastLoggedA4Hz = snapped
                    }
                },
                onReset = {
                    scope.launch { prefs.setA4ReferenceHz(440.0) }
                    if (lastLoggedA4Hz != 440.0) {
                        AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedA4(440.0))
                        lastLoggedA4Hz = 440.0
                    }
                },
            )
        }
        item {
            // Display mode dropdown (formerly labelled "Layout") — placed after A4 to match iOS Reader-section order.
            InspectorRow(
                label = stringResource(R.string.settings_reader_display_mode),
                leadingIcon = Icons.Filled.ViewArray,
            ) {
                val layoutModes = listOf(
                    Triple("vertical", stringResource(R.string.settings_layout_vertical), Icons.Filled.SwapVert),
                    Triple("horizontal", stringResource(R.string.settings_layout_horizontal), Icons.Filled.SwapHoriz),
                    Triple("page", stringResource(R.string.settings_layout_page), Icons.Filled.AutoStories),
                )
                var expanded by remember { mutableStateOf(false) }
                val current = layoutModes.firstOrNull { it.first == layout } ?: layoutModes.last()
                Box {
                    // Trigger row (icon + label + chevron) opens an anchored DropdownMenu — same
                    // menu-picker pattern as the Reader display inspector's layout-mode control.
                    Row(
                        Modifier.clickable { expanded = true }
                            .padding(horizontal = 4.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(current.third, contentDescription = null, modifier = Modifier.size(20.dp))
                        Text(current.second)
                        Icon(Icons.Filled.UnfoldMore, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                        layoutModes.forEach { (raw, label, icon) ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                leadingIcon = {
                                    Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
                                },
                                trailingIcon = if (raw == layout) {
                                    { Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp)) }
                                } else {
                                    null
                                },
                                onClick = {
                                    if (raw != layout) {
                                        AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedLayoutMode(raw))
                                    }
                                    scope.launch { prefs.setLayoutMode(raw) }
                                    expanded = false
                                },
                            )
                        }
                    }
                }
            }
        }
        item {
            SoundfontRow(
                state = sfState,
                isWiFi = { soundfontVM.isWiFiNow() },
                onSetOptedIn = { soundfontVM.setOptedIn(it) },
                onDownloadNow = { soundfontVM.startDownloadAllowingCellular() },
                onStop = { soundfontVM.cancelDownload() },
            )
        }
        item {
            Text(
                stringResource(R.string.settings_reader_continuation_footer),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // ── Privacy ───────────────────────────────────────────────────────────
        item {
            Spacer(Modifier.height(16.dp))
            InspectorSectionHeader(stringResource(R.string.settings_privacy_title))
        }
        item {
            ToggleRow(
                icon = Icons.Filled.BugReport,
                title = stringResource(R.string.settings_privacy_crash_title),
                subtitle = stringResource(R.string.settings_privacy_crash_description),
                checked = crashReporting,
                onChange = { v ->
                    scope.launch { prefs.setCrashReporting(v) }
                    CrashReporting.setCollectionEnabled(v)
                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("crashReporting", v))
                },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.Analytics,
                title = stringResource(R.string.settings_privacy_analytics_title),
                subtitle = stringResource(R.string.settings_privacy_analytics_description),
                checked = analyticsEnabled,
                onChange = { v ->
                    scope.launch { prefs.setAnalytics(v) }
                    AndroidAnalytics.setCollectionEnabled(v)
                    // Log AFTER toggling collection: enabling records the change; disabling is silently dropped by the
                    // now-off sink, so opting out never emits a parting event. Mirrors iOS PrivacySettingsSection.
                    AndroidAnalytics.log(AndroidAnalytics.bridge.settingChangedToggle("analytics", v))
                },
            )
        }

        // ── About ─────────────────────────────────────────────────────────────
        // The standalone inline version-history section has been removed; Version History is now a
        // navigation row inside the About section (wired when onOpenVersionHistory != null).
        if (onOpenLicenses != null) {
            item {
                Spacer(Modifier.height(16.dp))
                InspectorSectionHeader(stringResource(R.string.settings_about_title))
            }
            if (onOpenVersionHistory != null) {
                item {
                    InspectorRow(label = stringResource(R.string.settings_version_history), leadingIcon = Icons.Filled.History, onClick = onOpenVersionHistory) {
                        Icon(Icons.AutoMirrored.Filled.ArrowForwardIos, contentDescription = null)
                    }
                }
            }
            item {
                InspectorRow(label = stringResource(R.string.settings_about_licenses), leadingIcon = Icons.Filled.Description, onClick = onOpenLicenses) {
                    Icon(Icons.AutoMirrored.Filled.ArrowForwardIos, contentDescription = null)
                }
            }
            item {
                InspectorRow(label = stringResource(R.string.settings_about_send_feedback), leadingIcon = Icons.Filled.Email, onClick = { sendFeedback(context) }) {}
            }
        }
    }
}

/**
 * Opens the user's email app pre-filled with a feedback message. Mirrors iOS FeedbackMailView:
 * same recipient, "folino Feedback" subject, and an App Version / OS / Device header followed by a
 * blank "Feedback:" prompt. Shows a Toast if no email app can handle the intent (the Android
 * analogue of iOS canSendMail() being false).
 */
private fun sendFeedback(context: Context) {
    val body = buildString {
        append("App Version: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})\n")
        append("OS: Android ${Build.VERSION.RELEASE}\n")
        append("Device: ${Build.MANUFACTURER} ${Build.MODEL}\n\n")
        append("Feedback:\n")
    }
    val intent = Intent(Intent.ACTION_SENDTO).apply {
        data = Uri.parse("mailto:")
        putExtra(Intent.EXTRA_EMAIL, arrayOf("jiyi.meta@gmail.com"))
        putExtra(Intent.EXTRA_SUBJECT, "folino Feedback")
        putExtra(Intent.EXTRA_TEXT, body)
    }
    try {
        context.startActivity(intent)
    } catch (_: ActivityNotFoundException) {
        Toast.makeText(context, context.getString(R.string.settings_feedback_no_email_app), Toast.LENGTH_SHORT).show()
    }
}

@Composable
private fun ToggleRow(
    icon: ImageVector,
    title: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
    subtitle: String? = null,
) {
    InspectorRow(label = title, leadingIcon = icon, subtitle = subtitle) {
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

/**
 * High-quality SoundFont download row. Mirrors the iOS Reader settings entry: lets the user opt in to
 * downloading the ≈206 MB high-fidelity SoundFont, shows download progress with a Stop affordance, and
 * confirms before downloading over cellular or deleting the downloaded file (falling back to the bundled
 * SoundFont). Opt-in / status is read from the shared SoundfontStateWire so iOS and Android stay in parity.
 */
@Composable
private fun SoundfontRow(
    state: com.keynumber.folino.soundfont.SoundfontStateWire,
    isWiFi: () -> Boolean,
    onSetOptedIn: (Boolean) -> Unit,
    onDownloadNow: () -> Unit,
    onStop: () -> Unit,
) {
    var showCellularDialog by remember { mutableStateOf(false) }
    var showDeleteDialog by remember { mutableStateOf(false) }
    val optedIn = state.isOptedIn

    val downloadingTemplate = stringResource(R.string.settings_soundfont_downloading)
    val waitingWifi = stringResource(R.string.settings_soundfont_waiting_wifi)
    val sfSubtitle = stringResource(R.string.settings_soundfont_subtitle)
    val subtitle = when (state.statusRaw) {
        "downloading" -> String.format(downloadingTemplate, (state.progress * 100).toInt())
        "failed" -> state.failureReason
        "idle" -> if (optedIn) waitingWifi else sfSubtitle
        else -> "" // downloaded
    }

    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Filled.MusicNote,
            contentDescription = stringResource(R.string.settings_reader_high_quality_audio),
            modifier = Modifier.padding(end = 12.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Column(Modifier.weight(1f)) {
            Text(stringResource(R.string.settings_reader_high_quality_audio))
            if (subtitle.isNotEmpty()) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (state.statusRaw == "failed") {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                    },
                )
            }
            if (state.statusRaw == "idle" && optedIn) {
                TextButton(onClick = onDownloadNow, contentPadding = PaddingValues(0.dp)) {
                    Text(stringResource(R.string.settings_soundfont_download_now))
                }
            }
        }
        when {
            state.statusRaw == "downloading" -> {
                CircularProgressIndicator(
                    progress = { state.progress.toFloat() },
                    modifier = Modifier.size(24.dp),
                )
                IconButton(onClick = onStop) {
                    Icon(Icons.Filled.Stop, contentDescription = null)
                }
            }
            state.statusRaw == "idle" && optedIn -> {
                CircularProgressIndicator(modifier = Modifier.size(24.dp))
                IconButton(onClick = onStop) {
                    Icon(Icons.Filled.Stop, contentDescription = null)
                }
            }
            state.statusRaw == "idle" && !optedIn -> {
                Switch(
                    checked = false,
                    onCheckedChange = {
                        if (it) {
                            if (isWiFi()) onSetOptedIn(true) else showCellularDialog = true
                        }
                    },
                )
            }
            state.statusRaw == "downloaded" -> {
                Switch(
                    checked = true,
                    onCheckedChange = { if (!it) showDeleteDialog = true },
                )
            }
            state.statusRaw == "failed" -> {
                Switch(
                    checked = false,
                    onCheckedChange = { if (it) onSetOptedIn(true) },
                )
            }
        }
    }

    if (showCellularDialog) {
        AlertDialog(
            onDismissRequest = { showCellularDialog = false },
            title = { Text(stringResource(R.string.settings_soundfont_no_wifi_title)) },
            text = { Text(stringResource(R.string.settings_soundfont_no_wifi_message)) },
            confirmButton = {
                TextButton(onClick = {
                    showCellularDialog = false
                    onDownloadNow()
                }) { Text(stringResource(R.string.settings_soundfont_download_cellular)) }
            },
            dismissButton = {
                TextButton(onClick = {
                    showCellularDialog = false
                    onSetOptedIn(true)
                }) { Text(stringResource(R.string.settings_soundfont_wait_wifi)) }
            },
        )
    }

    if (showDeleteDialog) {
        AlertDialog(
            onDismissRequest = { showDeleteDialog = false },
            title = { Text(stringResource(R.string.settings_soundfont_delete_title)) },
            text = { Text(stringResource(R.string.settings_soundfont_delete_message)) },
            confirmButton = {
                TextButton(onClick = {
                    showDeleteDialog = false
                    onSetOptedIn(false)
                }) { Text(stringResource(R.string.settings_soundfont_delete_confirm)) }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteDialog = false }) { Text(stringResource(R.string.settings_common_cancel)) }
            },
        )
    }
}

data class VersionHistoryItem(val version: String, val descriptions: List<String>)

/**
 * Global A4 reference pitch row, now labelled "Default Calibration" (iOS parity). Shows:
 * tuning-fork icon + title on the left, "A4 = NNNHz" monospace readout on the right, a description
 * caption, and the 415–466 Hz slider. Snaps to 432 or 440 Hz on release when within 1 Hz.
 */
@Composable
private fun A4SliderRow(
    hz: Double,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: () -> Unit,
    onReset: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(TuningForkIcon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(stringResource(R.string.settings_a4_reference), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            Text(
                "A4 = ${hz.roundToInt()}Hz",
                style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
            )
        }
        Text(
            stringResource(R.string.reader_settings_a4_description),
            Modifier.padding(start = 32.dp),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        ResettableSlider(
            value = hz.toFloat(),
            onValueChange = onValueChange,
            onValueChangeFinished = onValueChangeFinished,
            // Standard concert pitch (440 Hz) is the default; double-tap restores it.
            defaultValue = 440f,
            onReset = onReset,
            valueRange = 415f..466f,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}
