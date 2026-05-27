package com.keynumber.folino.ui.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
        item { ToggleRow("Metronome", metronome) { v -> scope.launch { prefs.setMetronome(v) } } }
        item { ToggleRow("Picture in Picture", pip) { v -> scope.launch { prefs.setPip(v) } } }
        item { ToggleRow("Collapse multi-measure rests", collapse) { v -> scope.launch { prefs.setCollapseRests(v) } } }
        item { ToggleRow("Keep screen awake", keepAwake) { v -> scope.launch { prefs.setKeepAwake(v) } } }
        item {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
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
            Text("Version History", style = MaterialTheme.typography.titleSmall)
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
private fun ToggleRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

data class VersionHistoryItem(val version: String, val descriptions: List<String>)
