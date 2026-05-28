package com.keynumber.folino.ui.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
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
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(prefs: SettingsPrefs, versionHistory: List<VersionHistoryItem>) {
    val scope = rememberCoroutineScope()
    val metronome by prefs.metronome.collectAsState(initial = false)
    val pip by prefs.pip.collectAsState(initial = false)
    val collapse by prefs.collapseRests.collectAsState(initial = false)
    val keepAwake by prefs.keepAwake.collectAsState(initial = true)
    val layout by prefs.layoutMode.collectAsState(initial = "page")

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
