package com.keynumber.folino.reader

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.jiyimeta.sheetmusic.audio.model.GMInstrument
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel

/**
 * Playback controls panel for the Reader (Android port of the iOS playback inspector).
 *
 * A thin reactive binding over [ReaderAudioViewModel] / the playback engine: the engine
 * already owns all mix/playback semantics (shared with iOS), so this sheet only reads its
 * StateFlows and forwards user interaction to its setters. Controls are disabled until the
 * engine binds; the mixer is empty until a score is prepared. Per the approved design, the
 * slider feel / % readout are UI-only (Android-idiomatic), not shared via JNI.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaybackInspectorSheet(
    audioVm: ReaderAudioViewModel,
    sheetState: SheetState,
    onDismiss: () -> Unit,
) {
    val engine by audioVm.engine.collectAsStateWithLifecycle()
    val mixerChannels by audioVm.mixerChannels.collectAsStateWithLifecycle()
    val rate by audioVm.currentRate.collectAsStateWithLifecycle()
    val masterVolume by audioVm.masterVolume.collectAsStateWithLifecycle()
    val metronomeEnabled by audioVm.metronomeEnabled.collectAsStateWithLifecycle()

    val controlsEnabled = engine != null
    // GM catalog is shared Swift (loaded once via JNI, cached). Used by the program picker.
    val gmInstruments = remember { GMInstrument.entries }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // ── Master ──────────────────────────────────────────────
            SectionHeader("Master")
            LabeledSlider(
                label = "Volume",
                readout = "${(masterVolume * 100).toInt()}%",
                value = masterVolume,
                valueRange = 0f..1f,
                enabled = controlsEnabled,
                onValueChange = { audioVm.setMasterVolume(it) },
            )

            // ── Tempo ───────────────────────────────────────────────
            SectionHeader("Tempo")
            LabeledSlider(
                label = "Rate",
                readout = "×%.2f".format(rate),
                value = rate,
                valueRange = 0.5f..2.0f,
                enabled = controlsEnabled,
                onValueChange = { engine?.setRate(it) },
            )

            // ── Metronome ───────────────────────────────────────────
            SectionHeader("Metronome")
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Click")
                Switch(
                    checked = metronomeEnabled,
                    onCheckedChange = { audioVm.setMetronomeEnabled(it) },
                    enabled = controlsEnabled,
                )
            }

            // ── Mixer (per staff) ───────────────────────────────────
            HorizontalDivider()
            SectionHeader("Mixer")
            if (mixerChannels.isEmpty()) {
                Text("No parts to mix.")
            } else {
                mixerChannels.forEach { channel ->
                    MixerRow(
                        channel = channel,
                        enabled = controlsEnabled,
                        gmInstruments = gmInstruments,
                        onVolume = { engine?.setStaffVolume(channel.staffIndex, it) },
                        onMute = { engine?.setStaffMuted(channel.staffIndex, it) },
                        onSolo = { engine?.setStaffSoloed(channel.staffIndex, it) },
                        onProgram = { engine?.setStaffProgram(channel.staffIndex, it) },
                    )
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(text = title, style = MaterialTheme.typography.titleSmall)
}

@Composable
private fun LabeledSlider(
    label: String,
    readout: String,
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    enabled: Boolean,
    onValueChange: (Float) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(label, modifier = Modifier.width(56.dp))
        Slider(
            value = value,
            onValueChange = onValueChange,
            valueRange = valueRange,
            enabled = enabled,
            modifier = Modifier.weight(1f),
        )
        Text(readout, modifier = Modifier.width(56.dp))
    }
}

@Composable
private fun MixerRow(
    channel: MixerChannel,
    enabled: Boolean,
    gmInstruments: List<GMInstrument>,
    onVolume: (Float) -> Unit,
    onMute: (Boolean) -> Unit,
    onSolo: (Boolean) -> Unit,
    onProgram: (Int) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = channel.displayName,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            FilterChip(
                selected = channel.isSoloed,
                onClick = { onSolo(!channel.isSoloed) },
                label = { Text("S") },
                enabled = enabled,
            )
            FilterChip(
                selected = channel.isMuted,
                onClick = { onMute(!channel.isMuted) },
                label = { Text("M") },
                enabled = enabled,
            )
        }
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Slider(
                value = channel.volume,
                onValueChange = onVolume,
                valueRange = 0f..1f,
                // A soloed-elsewhere staff is effectively muted; reflect that the slider
                // won't be audible by disabling it, mirroring iOS's disabled state.
                enabled = enabled && !channel.effectiveMute,
                modifier = Modifier.weight(1f),
            )
            val program = channel.program
            if (program != null) {
                ProgramPickerButton(
                    program = program,
                    enabled = enabled,
                    gmInstruments = gmInstruments,
                    onProgram = onProgram,
                )
            } else {
                Text("Drums", modifier = Modifier.width(120.dp))
            }
        }
    }
}

@Composable
private fun ProgramPickerButton(
    program: Int,
    enabled: Boolean,
    gmInstruments: List<GMInstrument>,
    onProgram: (Int) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val name = gmInstruments.firstOrNull { it.program == program }?.displayName ?: "Program $program"
    Column {
        TextButton(onClick = { expanded = true }, enabled = enabled) {
            Text(
                text = name,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.width(96.dp),
            )
            Icon(Icons.Default.ArrowDropDown, contentDescription = "Choose instrument")
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            gmInstruments.forEach { instrument ->
                DropdownMenuItem(
                    text = { Text(instrument.displayName) },
                    onClick = {
                        onProgram(instrument.program)
                        expanded = false
                    },
                )
            }
        }
    }
}
