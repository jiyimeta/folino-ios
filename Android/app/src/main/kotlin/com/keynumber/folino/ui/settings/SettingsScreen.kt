package com.keynumber.folino.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForwardIos
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PictureInPicture
import androidx.compose.material.icons.filled.ScreenLockPortrait
import androidx.compose.material.icons.filled.UnfoldLess
import androidx.compose.material.icons.filled.ViewArray
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.keynumber.folino.R
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(
    prefs: SettingsPrefs,
    versionHistory: List<VersionHistoryItem>,
    onOpenLicenses: (() -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    val metronome by prefs.metronome.collectAsState(initial = false)
    val pip by prefs.pip.collectAsState(initial = false)
    val collapse by prefs.collapseRests.collectAsState(initial = false)
    val keepAwake by prefs.keepAwake.collectAsState(initial = true)
    val layout by prefs.layoutMode.collectAsState(initial = "page")
    val a4Hz by prefs.a4ReferenceHz.collectAsState(initial = 440.0)

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
                SingleChoiceSegmentedButtonRow {
                    listOf("vertical", "horizontal", "page").forEachIndexed { i, mode ->
                        SegmentedButton(
                            selected = layout == mode,
                            onClick = { scope.launch { prefs.setLayoutMode(mode) } },
                            shape = SegmentedButtonDefaults.itemShape(i, 3),
                        ) { Text(mode.take(1).uppercase()) }
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
        }
    }
}

@Composable
private fun ToggleRow(icon: ImageVector, title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = title,
            modifier = Modifier.padding(end = 12.dp),
        )
        Text(title, Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
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
