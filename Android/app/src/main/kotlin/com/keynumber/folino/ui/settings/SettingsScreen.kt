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
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PictureInPicture
import androidx.compose.material.icons.filled.ScreenLockPortrait
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.UnfoldLess
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.filled.ViewArray
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.filled.Repeat
import com.keynumber.folino.BuildConfig
import com.keynumber.folino.R
import com.keynumber.folino.diagnostics.CrashReporting
import com.keynumber.folino.reader.RepeatMode
import com.keynumber.folino.reader.RepeatModePicker
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(
    prefs: SettingsPrefs,
    versionHistory: List<VersionHistoryItem>,
    onOpenLicenses: (() -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val metronome by prefs.metronome.collectAsState(initial = false)
    val pip by prefs.pip.collectAsState(initial = false)
    val collapse by prefs.collapseRests.collectAsState(initial = false)
    val keepAwake by prefs.keepAwake.collectAsState(initial = true)
    val layout by prefs.layoutMode.collectAsState(initial = "page")
    val a4Hz by prefs.a4ReferenceHz.collectAsState(initial = 440.0)
    val crashReporting by prefs.crashReporting.collectAsState(initial = true)
    val repeatModeWire by prefs.repeatMode.collectAsState(initial = "off")
    val continuationModeWire by prefs.playlistContinuationMode.collectAsState(initial = "playThrough")
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
        item { Text("Reader", style = MaterialTheme.typography.titleSmall) }
        item {
            ToggleRow(
                icon = Icons.Filled.MusicNote,
                title = "Metronome",
                checked = metronome,
                onChange = { v -> scope.launch { prefs.setMetronome(v) } },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.PictureInPicture,
                title = "Picture in Picture",
                checked = pip,
                onChange = { v -> scope.launch { prefs.setPip(v) } },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.UnfoldLess,
                title = "Collapse multi-measure rests",
                checked = collapse,
                onChange = { v -> scope.launch { prefs.setCollapseRests(v) } },
            )
        }
        item {
            ToggleRow(
                icon = Icons.Filled.ScreenLockPortrait,
                title = "Keep screen awake",
                checked = keepAwake,
                onChange = { v -> scope.launch { prefs.setKeepAwake(v) } },
            )
        }
        item {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Filled.ViewArray,
                    contentDescription = "Layout",
                    modifier = Modifier.padding(end = 12.dp),
                )
                Text("Layout", Modifier.weight(1f))
                val layoutModes = listOf(
                    Triple("vertical", "Vertical", Icons.Filled.SwapVert),
                    Triple("horizontal", "Horizontal", Icons.Filled.SwapHoriz),
                    Triple("page", "Page", Icons.Filled.AutoStories),
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
                        Icon(Icons.Filled.UnfoldMore, contentDescription = null, modifier = Modifier.size(16.dp))
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
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Filled.Repeat,
                    contentDescription = "Repeat",
                    modifier = Modifier.padding(end = 12.dp),
                )
                Text("Repeat", Modifier.weight(1f))
                RepeatModePicker(
                    selected = RepeatMode.fromWire(repeatModeWire),
                    enabled = true,
                    onSelect = { scope.launch { prefs.setRepeatMode(it.wire) } },
                )
            }
        }
        item {
            // Global sticky playlist-continuation mode. Persist-only: the playlist continuous-playback
            // feature that consumes this value is not yet built on Android, so selecting only saves the
            // choice (no playback behavior is wired). Mirrors the iOS Settings continuation row wording.
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.PlaylistPlay,
                    contentDescription = stringResource(R.string.settings_playlist_continuation),
                    modifier = Modifier.padding(end = 12.dp),
                )
                Text(stringResource(R.string.settings_playlist_continuation), Modifier.weight(1f))
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
                        Icon(Icons.Filled.UnfoldMore, contentDescription = null, modifier = Modifier.size(16.dp))
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
                },
            )
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
            Spacer(Modifier.height(16.dp))
            Text(stringResource(R.string.settings_privacy_title), style = MaterialTheme.typography.titleSmall)
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
                },
            )
        }
        // Empty when suppressed (e.g. the 1.0.0 first-release guard in MainActivity); hide the whole section,
        // header included, so we never render a bare "Version History" heading with no entries.
        if (versionHistory.isNotEmpty()) {
            item {
                Spacer(Modifier.height(16.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Filled.History,
                        contentDescription = "Version History",
                        modifier = Modifier.padding(end = 8.dp),
                    )
                    Text("Version History", style = MaterialTheme.typography.titleSmall)
                }
            }
            items(versionHistory.size) { idx ->
                val v = versionHistory[idx]
                Column {
                    Text(v.version, style = MaterialTheme.typography.titleMedium)
                    v.descriptions.forEach { Text("• $it", style = MaterialTheme.typography.bodyMedium) }
                }
            }
        }
        if (onOpenLicenses != null) {
            item {
                Spacer(Modifier.height(16.dp))
                Text("About", style = MaterialTheme.typography.titleSmall)
            }
            item {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { onOpenLicenses() }
                        .padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Filled.Description,
                        contentDescription = "Licenses",
                        modifier = Modifier.padding(end = 12.dp),
                    )
                    Text("Licenses", Modifier.weight(1f))
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowForwardIos,
                        contentDescription = null,
                    )
                }
            }
            item {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { sendFeedback(context) }
                        .padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Filled.Email,
                        contentDescription = "Send Feedback",
                        modifier = Modifier.padding(end = 12.dp),
                    )
                    Text("Send Feedback", Modifier.weight(1f))
                }
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
        Toast.makeText(context, "No email app found", Toast.LENGTH_SHORT).show()
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
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = title,
            modifier = Modifier.padding(end = 12.dp),
        )
        Column(Modifier.weight(1f)) {
            Text(title)
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
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

    val subtitle = when (state.statusRaw) {
        "downloading" -> "Downloading… ${(state.progress * 100).toInt()}%"
        "failed" -> state.failureReason
        "idle" -> if (optedIn) "Waiting for Wi-Fi" else "High-fidelity instruments (≈206 MB)"
        else -> "" // downloaded
    }

    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Filled.MusicNote,
            contentDescription = "High-Quality SoundFont",
            modifier = Modifier.padding(end = 12.dp),
        )
        Column(Modifier.weight(1f)) {
            Text("High-Quality SoundFont")
            if (subtitle.isNotEmpty()) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (state.statusRaw == "failed") {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
            if (state.statusRaw == "idle" && optedIn) {
                TextButton(onClick = onDownloadNow, contentPadding = PaddingValues(0.dp)) {
                    Text("Download now")
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
                    Icon(Icons.Filled.Stop, contentDescription = "Stop")
                }
            }
            state.statusRaw == "idle" && optedIn -> {
                CircularProgressIndicator(modifier = Modifier.size(24.dp))
                IconButton(onClick = onStop) {
                    Icon(Icons.Filled.Stop, contentDescription = "Stop")
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
            title = { Text("No Wi-Fi") },
            text = { Text("You're not on Wi-Fi. The high-quality SoundFont is about 206 MB.") },
            confirmButton = {
                TextButton(onClick = {
                    showCellularDialog = false
                    onDownloadNow()
                }) { Text("Download over cellular") }
            },
            dismissButton = {
                TextButton(onClick = {
                    showCellularDialog = false
                    onSetOptedIn(true)
                }) { Text("Wait for Wi-Fi") }
            },
        )
    }

    if (showDeleteDialog) {
        AlertDialog(
            onDismissRequest = { showDeleteDialog = false },
            title = { Text("Delete download") },
            text = { Text("Remove the high-quality SoundFont and use the bundled one?") },
            confirmButton = {
                TextButton(onClick = {
                    showDeleteDialog = false
                    onSetOptedIn(false)
                }) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteDialog = false }) { Text("Cancel") }
            },
        )
    }
}

data class VersionHistoryItem(val version: String, val descriptions: List<String>)

/**
 * Global A4 reference pitch slider row (415–466 Hz).
 * Title shows "A4 = NNNHz" (mirroring iOS; no space before "Hz"). A description line below
 * tells the user the value applies to all scores but can be overridden per-score.
 * Snaps to 432 or 440 Hz on release when within 1 Hz of either value.
 */
@Composable
private fun A4SliderRow(
    hz: Double,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: () -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = Icons.Filled.MusicNote,
                contentDescription = stringResource(R.string.settings_a4_reference),
                modifier = Modifier.padding(end = 12.dp),
            )
            Text(
                "A4 = ${hz.roundToInt()}Hz",
                Modifier.weight(1f),
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        Text(
            stringResource(R.string.reader_settings_a4_description),
            modifier = Modifier.padding(start = 36.dp),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Slider(
            value = hz.toFloat(),
            onValueChange = onValueChange,
            onValueChangeFinished = onValueChangeFinished,
            valueRange = 415f..466f,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}
