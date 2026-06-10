package com.keynumber.folino.reader

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.reader.ui.CollapsibleHeader
import io.github.jiyimeta.sheetmusic.audio.model.GMInstrument
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import kotlin.math.ln
import kotlin.math.roundToInt

/** Compact slider height so the mixer's many rows don't dominate the sheet. */
private val sliderHeight = 24.dp

/** Small square footprint for the per-staff Solo / Mute toggles. */
private val toggleSize = 36.dp

/**
 * Playback controls panel for the Reader (Android port of the iOS playback inspector).
 *
 * A thin reactive binding over [ReaderAudioViewModel] / the playback engine: the engine
 * already owns all mix/playback semantics (shared with iOS), so this sheet only reads its
 * StateFlows and forwards user interaction to its setters. Controls are disabled until the
 * engine binds; the mixer is empty until a score is prepared.
 *
 * Layout is tuned for information density (mirroring the iOS Form inspector while staying
 * Material-idiomatic): whole-score controls are grouped under one collapsible "General"
 * header with leading icons instead of text labels, the per-staff mixer is a collapsible
 * `LazyColumn`, Solo/Mute are compact icon toggles, and row spacing is tight.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaybackInspectorSheet(
    audioVm: ReaderAudioViewModel,
    openingQuarterBpm: Double,
    sheetState: SheetState,
    onDismiss: () -> Unit,
    /** Global metronome-enabled flag (SettingsPrefs); metronome is global on both platforms. */
    metronomeEnabled: Boolean = false,
    /** Writes the global metronome flag on toggle. */
    onMetronomeChange: (Boolean) -> Unit = {},
    /** Persists the per-score master volume after the live engine/VM update. */
    onPersistMasterVolume: (Double) -> Unit = {},
    /** Persists the per-score tempo multiplier after the live engine update. */
    onPersistTempoMultiplier: (Double) -> Unit = {},
    /** Persists the per-score A4 reference pitch after the live engine/VM update. */
    onPersistA4ReferenceHz: (Double) -> Unit = {},
    /** Current per-score transpose value in semitones (−7..7), restored from the ReaderPreferences bridge. */
    transposeSemitones: Int = 0,
    /** Persists the per-score transpose value (semitones) via the ReaderPreferences bridge. */
    onTransposeChange: (Int) -> Unit = {},
    /** Flat mixer staffIndex -> positional StaffAddress, for persisting per-staff overrides. */
    staffAddressByIndex: Map<Int, StaffAddress> = emptyMap(),
    /** Persists a per-score program override (by staff address) after the live engine update. */
    onPersistStaffProgram: (StaffAddress, Int) -> Unit = { _, _ -> },
    /** Persists a per-score volume override (by staff address) after the live engine update. */
    onPersistStaffVolume: (StaffAddress, Float) -> Unit = { _, _ -> },
) {
    val engine by audioVm.engine.collectAsStateWithLifecycle()
    val mixerChannels by audioVm.mixerChannels.collectAsStateWithLifecycle()
    val rate by audioVm.currentRate.collectAsStateWithLifecycle()
    val masterVolume by audioVm.masterVolume.collectAsStateWithLifecycle()
    val a4ReferenceHz by audioVm.a4ReferenceHz.collectAsStateWithLifecycle()
    val globalA4ReferenceHz by audioVm.globalA4ReferenceHz.collectAsStateWithLifecycle()
    val repeatMode by audioVm.repeatMode.collectAsStateWithLifecycle()

    val controlsEnabled = engine != null
    // GM catalog is shared Swift (loaded once via JNI, cached). Used by the program picker.
    val gmInstruments = remember { GMInstrument.entries }

    var generalExpanded by rememberSaveable { mutableStateOf(true) }
    var mixerExpanded by rememberSaveable { mutableStateOf(true) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        LazyColumn(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
        ) {
            // ── General (master / tempo / metronome) ────────────────
            item {
                CollapsibleHeader("General", generalExpanded) { generalExpanded = !generalExpanded }
            }
            if (generalExpanded) {
                item {
                    IconSliderRow(
                        icon = Icons.Default.VolumeUp,
                        label = "Volume",
                        value = masterVolume,
                        valueRange = 0f..1f,
                        readout = "${(masterVolume * 100).toInt()}%",
                        enabled = controlsEnabled,
                        onValueChange = {
                            audioVm.setMasterVolume(it)
                            onPersistMasterVolume(it.toDouble())
                        },
                    )
                }
                item {
                    IconSliderRow(
                        icon = Icons.Default.Speed,
                        label = "Tempo",
                        value = rate,
                        valueRange = 0.5f..2.0f,
                        // Engraved-style readout (quarter-note glyph + BPM), matching iOS.
                        readout = "♩ = ${(openingQuarterBpm * rate).roundToInt()}",
                        enabled = controlsEnabled,
                        onValueChange = {
                            engine?.setRate(it)
                            onPersistTempoMultiplier(it.toDouble())
                        },
                    )
                }
                item {
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(Icons.Default.Timer, contentDescription = null)
                        Text("Metronome", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        Switch(
                            // Metronome is a GLOBAL setting (SettingsPrefs), not per-score. The toggle
                            // writes the global flag; the Reader screen pushes that value into the engine
                            // via [ReaderAudioViewModel.setMetronomeEnabled] (which also survives a
                            // soundfont hot-swap re-push).
                            checked = metronomeEnabled,
                            onCheckedChange = { onMetronomeChange(it) },
                            enabled = controlsEnabled,
                        )
                    }
                }
                item {
                    A4ReferenceRow(
                        hz = a4ReferenceHz,
                        globalHz = globalA4ReferenceHz,
                        enabled = controlsEnabled,
                        // Live-update the engine/VM while dragging, but only persist on release
                        // (onValueChangeFinished) + on each ± step, so a drag doesn't write the store
                        // on every frame.
                        onValueChange = { audioVm.setA4ReferenceHz(it.toDouble()) },
                        onValueChangeFinished = {
                            val snapped = snapA4Hz(a4ReferenceHz)
                            audioVm.setA4ReferenceHz(snapped)
                            onPersistA4ReferenceHz(snapped)
                        },
                        onStep = { delta ->
                            val next = (a4ReferenceHz + delta).coerceIn(415.0, 466.0)
                            audioVm.setA4ReferenceHz(next)
                            onPersistA4ReferenceHz(next)
                        },
                    )
                }
                item {
                    // Persist-only: the audio/notation transpose effect is not yet implemented on Android
                    // (see spec Non-Goals). This row stores transposeSemitones via the ReaderPreferences
                    // bridge for a future transpose feature.
                    TransposeRow(
                        semitones = transposeSemitones,
                        enabled = controlsEnabled,
                        onChange = onTransposeChange,
                    )
                }
                item {
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(Icons.Default.Repeat, contentDescription = null)
                        Text(
                            stringResource(R.string.reader_repeat_label),
                            Modifier.weight(1f),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        RepeatModePicker(
                            selected = repeatMode,
                            enabled = controlsEnabled,
                            onSelect = { audioVm.setRepeatMode(it) },
                        )
                    }
                }
            }

            item { HorizontalDivider(Modifier.padding(vertical = 4.dp)) }

            // ── Mixer (per staff) ───────────────────────────────────
            item {
                CollapsibleHeader("Mixer", mixerExpanded) { mixerExpanded = !mixerExpanded }
            }
            if (mixerExpanded) {
                if (mixerChannels.isEmpty()) {
                    item { Text("No parts to mix.", Modifier.padding(vertical = 4.dp)) }
                } else {
                    items(mixerChannels, key = { it.staffIndex }) { channel ->
                        // The flat mixer staffIndex maps to a positional StaffAddress for persistence;
                        // mute / solo stay session-only (not persisted), matching iOS.
                        val address = staffAddressByIndex[channel.staffIndex]
                        MixerRow(
                            channel = channel,
                            enabled = controlsEnabled,
                            gmInstruments = gmInstruments,
                            onVolume = {
                                engine?.setStaffVolume(channel.staffIndex, it)
                                address?.let { a -> onPersistStaffVolume(a, it) }
                            },
                            onMute = { engine?.setStaffMuted(channel.staffIndex, it) },
                            onSolo = { engine?.setStaffSoloed(channel.staffIndex, it) },
                            onProgram = {
                                engine?.setStaffProgram(channel.staffIndex, it)
                                address?.let { a -> onPersistStaffProgram(a, it) }
                            },
                        )
                        // Per-row separator — Material has no Form-style automatic divider,
                        // so we add a light one between staves for visual grouping.
                        HorizontalDivider(
                            Modifier.padding(top = 2.dp),
                            color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun IconSliderRow(
    icon: ImageVector,
    label: String,
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    readout: String,
    enabled: Boolean,
    onValueChange: (Float) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, contentDescription = null)
        // Text label (not icon-only) so the control is self-explanatory, matching iOS.
        Text(
            label,
            modifier = Modifier.width(76.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodyMedium,
        )
        Slider(
            value = value,
            onValueChange = onValueChange,
            valueRange = valueRange,
            enabled = enabled,
            modifier = Modifier.weight(1f).height(sliderHeight),
        )
        Text(
            readout,
            modifier = Modifier.width(64.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

/**
 * Snaps [hz] to 432 or 440 when within ~1.0 Hz of either common reference pitch.
 * Returns [hz] unchanged when not near a snap point.
 */
private fun snapA4Hz(hz: Double): Double = when {
    kotlin.math.abs(hz - 432.0) <= 1.0 -> 432.0
    kotlin.math.abs(hz - 440.0) <= 1.0 -> 440.0
    else -> hz
}

/**
 * A4 pitch-calibration row. Mirrors the iOS inspector design:
 * - Top line: "A4 = NNNHz" readout + compact ± stepper (1 Hz steps, 415–466 Hz range).
 * - Bottom line: global-relative readout ("440Hz +8セント") pinned to a fixed width so
 *   the slider never reflows, followed by the full-range whole-hertz slider.
 *
 * Stepping from the inherited global value or moving the slider creates a per-score override.
 * Snaps to 432 or 440 Hz on slider release when within 1 Hz of either value.
 */
@Composable
private fun A4ReferenceRow(
    hz: Double,
    globalHz: Double,
    enabled: Boolean,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: () -> Unit,
    onStep: (Double) -> Unit,
) {
    // Cents offset of [hz] from [globalHz], same formula as iOS: 1200·log2(hz/globalHz).
    val centsOffset = (1200.0 * (ln(hz) - ln(globalHz)) / ln(2.0)).roundToInt()
    val signedCents = if (centsOffset == 0) "±0" else "%+d".format(centsOffset)
    val relativeReadout = stringResource(
        R.string.reader_playback_a4_relative,
        globalHz.roundToInt(),
        signedCents,
    )
    // Widest sizing string: 3-digit Hz + signed 3-digit cents (e.g. "888Hz -888セント").
    val sizingReadout = stringResource(R.string.reader_playback_a4_relative, 888, "-888")

    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Tuning-fork icon, accent-tinted to match iOS.
        Icon(
            Icons.Default.MusicNote,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            // ── Top line: readout + ± stepper ───────────────────────
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = "A4 = ${hz.roundToInt()}Hz",
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.bodyMedium.copy(
                        fontFamily = FontFamily.Monospace,
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                // ± stepper: two compact IconButtons mirroring iOS's Stepper control.
                IconButton(
                    onClick = { onStep(-1.0) },
                    enabled = enabled && hz > 415.0,
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(
                        Icons.Default.Remove,
                        contentDescription = "Decrease A4",
                        modifier = Modifier.size(16.dp),
                    )
                }
                IconButton(
                    onClick = { onStep(+1.0) },
                    enabled = enabled && hz < 466.0,
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(
                        Icons.Default.Add,
                        contentDescription = "Increase A4",
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
            // ── Bottom line: fixed-width relative readout + slider ──
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Fixed-width Box: the hidden sizing text pins the width; the real text overlays it.
                Box {
                    // Invisible widest-possible string to reserve the full column width.
                    Text(
                        text = sizingReadout,
                        modifier = Modifier.alpha(0f),
                        style = MaterialTheme.typography.labelSmall.copy(
                            fontFamily = FontFamily.Monospace,
                        ),
                        maxLines = 1,
                    )
                    Text(
                        text = relativeReadout,
                        style = MaterialTheme.typography.labelSmall.copy(
                            fontFamily = FontFamily.Monospace,
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                    )
                }
                Slider(
                    value = hz.toFloat(),
                    onValueChange = onValueChange,
                    onValueChangeFinished = onValueChangeFinished,
                    valueRange = 415f..466f,
                    enabled = enabled,
                    modifier = Modifier.weight(1f).height(sliderHeight),
                )
            }
        }
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
    // Dense two-line strip mirroring iOS: identity row (name + wide program picker), then
    // the volume slider with Solo / Mute beside it. Keeping S/M off the name row lets the
    // program name use most of the width (it was clamping before). Placement is
    // Android-idiomatic; the content stays at iOS parity (shared displayName, GM names).
    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
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
                style = MaterialTheme.typography.bodyMedium,
            )
            val program = channel.program
            if (program != null) {
                ProgramPickerButton(
                    program = program,
                    enabled = enabled,
                    gmInstruments = gmInstruments,
                    modifier = Modifier.weight(1.6f),
                    onProgram = onProgram,
                )
            } else {
                Text(
                    "Drums",
                    modifier = Modifier.weight(1.6f),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Slider(
                value = channel.volume,
                onValueChange = onVolume,
                valueRange = 0f..1f,
                // A soloed-elsewhere staff is effectively muted; reflect that the slider
                // won't be audible by disabling it, mirroring iOS's disabled state.
                enabled = enabled && !channel.effectiveMute,
                modifier = Modifier.weight(1f).height(sliderHeight),
            )
            SmallToggle("S", channel.isSoloed, enabled, "Solo") { onSolo(!channel.isSoloed) }
            SmallToggle("M", channel.isMuted, enabled, "Mute") { onMute(!channel.isMuted) }
        }
    }
}

@Composable
private fun SmallToggle(
    label: String,
    checked: Boolean,
    enabled: Boolean,
    role: String,
    onToggle: () -> Unit,
) {
    FilledIconToggleButton(
        checked = checked,
        onCheckedChange = { onToggle() },
        enabled = enabled,
        modifier = Modifier.size(toggleSize).semantics {
            contentDescription = "$role ${if (checked) "on" else "off"}"
        },
    ) {
        Text(label, style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
private fun ProgramPickerButton(
    program: Int,
    enabled: Boolean,
    gmInstruments: List<GMInstrument>,
    modifier: Modifier = Modifier,
    onProgram: (Int) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val name = remember(program) {
        GMInstrument.forProgram(program)?.displayName ?: "Program $program"
    }
    Column(modifier) {
        TextButton(
            onClick = { expanded = true },
            enabled = enabled,
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                text = name,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.bodySmall,
            )
            Icon(Icons.Default.ArrowDropDown, contentDescription = "Choose instrument")
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            Column(
                Modifier
                    .heightIn(max = 320.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
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
}
