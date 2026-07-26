package com.keynumber.folino.reader

import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistPlay
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.UnfoldMore
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
import com.keynumber.folino.reader.ui.InspectorRow
import com.keynumber.folino.reader.ui.InspectorSectionHeader
import com.keynumber.folino.reader.ui.InspectorSliderHeight
import com.keynumber.folino.reader.ui.InspectorSliderRow
import com.keynumber.folino.reader.ui.MetronomeIcon
import com.keynumber.folino.reader.ui.ResettableSlider
import com.keynumber.folino.reader.ui.TuningForkIcon
import io.github.jiyimeta.sheetmusic.audio.model.GMInstrument
import kotlin.math.ln
import kotlin.math.roundToInt

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
    /** Bank-128 kit catalog for percussion parts, supplied by the composition root (shared Swift owns
     * the list — see [DrumKitOption]). Empty means no kit picker is offered. */
    drumKits: List<DrumKitOption> = emptyList(),
    /** Family display names, indexed by [DrumKitOption.familyIndex]; used as dropdown section headers. */
    drumKitFamilyNames: List<String> = emptyList(),
    /** Persists a per-score volume override (by staff address) after the live engine update. */
    onPersistStaffVolume: (StaffAddress, Float) -> Unit = { _, _ -> },
    /** True when this score is part of a playlist; shows the continuation-mode row. */
    isInPlaylist: Boolean = false,
    /** Wire string for the playlist continuation mode ("off" / "playThrough" / "loopPlaylist"). */
    continuationModeWire: String = "playThrough",
    /** Called when the user selects a new continuation mode. */
    onContinuationModeChange: (String) -> Unit = {},
    /** Ordered part display names, for grouping the mixer by part. */
    partNames: List<String> = emptyList(),
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        PlaybackInspectorContent(
            audioVm = audioVm,
            openingQuarterBpm = openingQuarterBpm,
            metronomeEnabled = metronomeEnabled,
            onMetronomeChange = onMetronomeChange,
            onPersistMasterVolume = onPersistMasterVolume,
            onPersistTempoMultiplier = onPersistTempoMultiplier,
            onPersistA4ReferenceHz = onPersistA4ReferenceHz,
            transposeSemitones = transposeSemitones,
            onTransposeChange = onTransposeChange,
            staffAddressByIndex = staffAddressByIndex,
            onPersistStaffProgram = onPersistStaffProgram,
            drumKits = drumKits,
            drumKitFamilyNames = drumKitFamilyNames,
            onPersistStaffVolume = onPersistStaffVolume,
            isInPlaylist = isInPlaylist,
            continuationModeWire = continuationModeWire,
            onContinuationModeChange = onContinuationModeChange,
            partNames = partNames,
        )
    }
}

/**
 * The scrollable body of the playback inspector, factored out of [PlaybackInspectorSheet] so the same
 * General + Parts control list can be hosted either inside the production `ModalBottomSheet` or — for
 * static capture harnesses, which can't render a separate sheet window into a node bitmap — directly in
 * a plain surface. The sheet wrapper owns the modal chrome; this composable owns only the control rows.
 */
@Composable
fun PlaybackInspectorContent(
    audioVm: ReaderAudioViewModel,
    openingQuarterBpm: Double,
    modifier: Modifier = Modifier,
    metronomeEnabled: Boolean = false,
    onMetronomeChange: (Boolean) -> Unit = {},
    onPersistMasterVolume: (Double) -> Unit = {},
    onPersistTempoMultiplier: (Double) -> Unit = {},
    onPersistA4ReferenceHz: (Double) -> Unit = {},
    transposeSemitones: Int = 0,
    onTransposeChange: (Int) -> Unit = {},
    staffAddressByIndex: Map<Int, StaffAddress> = emptyMap(),
    onPersistStaffProgram: (StaffAddress, Int) -> Unit = { _, _ -> },
    /** Bank-128 kit catalog for percussion parts, supplied by the composition root (shared Swift owns
     * the list — see [DrumKitOption]). Empty means no kit picker is offered. */
    drumKits: List<DrumKitOption> = emptyList(),
    /** Family display names, indexed by [DrumKitOption.familyIndex]; used as dropdown section headers. */
    drumKitFamilyNames: List<String> = emptyList(),
    onPersistStaffVolume: (StaffAddress, Float) -> Unit = { _, _ -> },
    isInPlaylist: Boolean = false,
    continuationModeWire: String = "playThrough",
    onContinuationModeChange: (String) -> Unit = {},
    partNames: List<String> = emptyList(),
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

    LazyColumn(
        modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .padding(bottom = 24.dp),
    ) {
            // ── General (master / tempo / metronome) ────────────────
            item {
                CollapsibleHeader(stringResource(R.string.reader_inspector_general), generalExpanded) { generalExpanded = !generalExpanded }
            }
            if (generalExpanded) {
                item {
                    InspectorRow(label = stringResource(R.string.reader_playback_metronome), leadingIcon = MetronomeIcon) {
                        // Metronome is a GLOBAL setting (SettingsPrefs), not per-score. The toggle
                        // writes the global flag; the Reader screen pushes that value into the engine
                        // via [ReaderAudioViewModel.setMetronomeEnabled] (which also survives a
                        // soundfont hot-swap re-push).
                        Switch(checked = metronomeEnabled, onCheckedChange = onMetronomeChange, enabled = controlsEnabled)
                    }
                }
                item {
                    TempoRow(
                        openingQuarterBpm = openingQuarterBpm,
                        rate = rate,
                        enabled = controlsEnabled,
                        onRate = { engine?.setRate(it); onPersistTempoMultiplier(it.toDouble()) },
                    )
                }
                item {
                    InspectorRow(label = stringResource(R.string.reader_repeat_label), leadingIcon = Icons.Default.Repeat) {
                        RepeatModePicker(selected = repeatMode, enabled = controlsEnabled, onSelect = { audioVm.setRepeatMode(it) })
                    }
                }
                if (isInPlaylist) {
                    item {
                        ContinuationRow(
                            modeWire = continuationModeWire,
                            repeatActive = repeatMode != RepeatMode.OFF,
                            enabled = controlsEnabled,
                            onSelect = onContinuationModeChange,
                        )
                    }
                }
                item {
                    InspectorSliderRow(
                        leadingIcon = Icons.Default.VolumeUp,
                        label = {
                            Text(
                                stringResource(R.string.reader_playback_volume),
                                Modifier.width(76.dp),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        },
                        trailing = {
                            Text(
                                "${(masterVolume * 100).toInt()}%",
                                Modifier.width(64.dp),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        },
                    ) {
                        ResettableSlider(
                            value = masterVolume,
                            onValueChange = {
                                audioVm.setMasterVolume(it)
                                onPersistMasterVolume(it.toDouble())
                            },
                            // Master volume has no score-authored value; unity (100%) is the default.
                            defaultValue = 1f,
                            onReset = {
                                audioVm.setMasterVolume(1f)
                                onPersistMasterVolume(1.0)
                            },
                            valueRange = 0f..1f,
                            enabled = controlsEnabled,
                            modifier = Modifier.weight(1f).height(InspectorSliderHeight),
                        )
                    }
                }
                item { TransposeRow(semitones = transposeSemitones, enabled = controlsEnabled, onChange = onTransposeChange) }
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
                        // Double-tap resets the per-score A4 to the inherited global reference,
                        // matching iOS where reset clears the per-score override.
                        onReset = {
                            audioVm.setA4ReferenceHz(globalA4ReferenceHz)
                            onPersistA4ReferenceHz(globalA4ReferenceHz)
                        },
                    )
                }
            }

            item { HorizontalDivider(Modifier.padding(vertical = 4.dp)) }

            // ── Parts (per-part mixer, iOS parity) ─────────────────
            item { CollapsibleHeader(stringResource(R.string.reader_inspector_parts), mixerExpanded) { mixerExpanded = !mixerExpanded } }
            if (mixerExpanded) {
                val groups = groupMixerByPart(mixerChannels, staffAddressByIndex, partNames)
                if (groups.isEmpty()) {
                    item { Text(stringResource(R.string.reader_mixer_empty), Modifier.padding(vertical = 4.dp)) }
                } else {
                    groups.forEach { group ->
                        item(key = "part-${group.partIndex}") {
                            PartMixerSection(
                                group = group,
                                enabled = controlsEnabled,
                                gmInstruments = gmInstruments,
                                drumKits = drumKits,
                                drumKitFamilyNames = drumKitFamilyNames,
                                onVolume = { idx, v ->
                                    engine?.setStaffVolume(idx, v)
                                    staffAddressByIndex[idx]?.let { onPersistStaffVolume(it, v) }
                                },
                                onMute = { idx, m -> engine?.setStaffMuted(idx, m) },
                                onSolo = { idx, s -> engine?.setStaffSoloed(idx, s) },
                                onProgram = { program ->
                                    group.channels.forEach { ch ->
                                        engine?.setStaffProgram(ch.staffIndex, program)
                                        staffAddressByIndex[ch.staffIndex]?.let { onPersistStaffProgram(it, program) }
                                    }
                                },
                            )
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

/**
 * Two-line tempo row. Top line: engraved quarter-note marking + BPM readout (tap to reset to 1×)
 * + ± stepper. Bottom line: percentage readout + multiplier slider.
 *
 * Android exposes only the tempo multiplier and opening quarter BPM (no governing-tempo beat glyph
 * like iOS), so the marking always uses the quarter-note glyph (♩).
 */
@Composable
private fun TempoRow(
    openingQuarterBpm: Double,
    rate: Float,
    enabled: Boolean,
    onRate: (Float) -> Unit,
) {
    val minRate = 0.5f
    val maxRate = 2.0f
    val bpm = (openingQuarterBpm * rate).roundToInt()
    val percent = (rate * 100).roundToInt()
    InspectorSliderRow(leadingIcon = Icons.Default.Speed) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            // Top line: engraved-style marking (quarter-note glyph + BPM, tap to reset) + ± stepper.
            // Android exposes only the tempo multiplier + opening quarter BPM (no governing-tempo
            // beat glyph like iOS), so the marking always uses the quarter-note glyph.
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = "♩ = $bpm",
                    modifier = Modifier.weight(1f).clickable(enabled = enabled) { onRate(1.0f) },
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                )
                IconButton(
                    onClick = { onRate(((bpm - 1) / openingQuarterBpm).toFloat().coerceIn(minRate, maxRate)) },
                    enabled = enabled && rate > minRate,
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(Icons.Default.Remove, contentDescription = stringResource(R.string.reader_tempo_decrease), modifier = Modifier.size(16.dp))
                }
                IconButton(
                    onClick = { onRate(((bpm + 1) / openingQuarterBpm).toFloat().coerceIn(minRate, maxRate)) },
                    enabled = enabled && rate < maxRate,
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(Icons.Default.Add, contentDescription = stringResource(R.string.reader_tempo_increase), modifier = Modifier.size(16.dp))
                }
            }
            // Bottom line: percent readout + multiplier slider.
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "$percent%",
                    Modifier.width(44.dp),
                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
                ResettableSlider(
                    value = rate,
                    onValueChange = onRate,
                    // 1× (the score's notated tempo) is the default; double-tap snaps back to it.
                    defaultValue = 1.0f,
                    onReset = { onRate(1.0f) },
                    valueRange = minRate..maxRate,
                    enabled = enabled,
                    modifier = Modifier.weight(1f).height(InspectorSliderHeight),
                )
            }
        }
    }
}

/**
 * Playlist continuation-mode row. Only shown when the score is part of a playlist
 * ([isInPlaylist] == true in [PlaybackInspectorSheet]).
 *
 * When the current repeat mode is active (A-B or loop-all), the picker is disabled and a
 * note explains why — mirroring iOS behavior where repeat takes precedence over continuation.
 */
@Composable
private fun ContinuationRow(
    modeWire: String,
    repeatActive: Boolean,
    enabled: Boolean,
    onSelect: (String) -> Unit,
) {
    val modes = listOf(
        "off" to stringResource(R.string.reader_continuation_off),
        "playThrough" to stringResource(R.string.reader_continuation_play_through),
        "loopPlaylist" to stringResource(R.string.reader_continuation_loop),
    )
    Column(Modifier.fillMaxWidth()) {
        InspectorRow(
            label = stringResource(R.string.reader_inspector_continuation),
            leadingIcon = Icons.AutoMirrored.Filled.PlaylistPlay,
        ) {
            var expanded by remember { mutableStateOf(false) }
            val current = modes.firstOrNull { it.first == modeWire } ?: modes[1]
            Box {
                Row(
                    Modifier
                        .clickable(enabled = enabled && !repeatActive) { expanded = true }
                        .padding(horizontal = 4.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        current.second,
                        color = if (repeatActive) {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        } else {
                            MaterialTheme.colorScheme.onSurface
                        },
                    )
                    Icon(Icons.Default.UnfoldMore, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    modes.forEach { (raw, label) ->
                        DropdownMenuItem(
                            text = { Text(label) },
                            trailingIcon = if (raw == modeWire) {
                                { Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp)) }
                            } else {
                                null
                            },
                            onClick = { onSelect(raw); expanded = false },
                        )
                    }
                }
            }
        }
        if (repeatActive) {
            Text(
                stringResource(R.string.reader_continuation_repeat_active),
                Modifier.padding(start = 32.dp, bottom = 4.dp),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
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
    onReset: () -> Unit,
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
        // Tuning-fork icon, neutral tint.
        Icon(
            TuningForkIcon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
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
                ResettableSlider(
                    value = hz.toFloat(),
                    onValueChange = onValueChange,
                    onValueChangeFinished = onValueChangeFinished,
                    // Tick + reset target sit at the inherited global reference pitch.
                    defaultValue = globalHz.toFloat(),
                    onReset = onReset,
                    valueRange = 415f..466f,
                    enabled = enabled,
                    modifier = Modifier.weight(1f).height(InspectorSliderHeight),
                )
            }
        }
    }
}

@Composable
private fun PartMixerSection(
    group: PartMixerGroup,
    enabled: Boolean,
    gmInstruments: List<GMInstrument>,
    drumKits: List<DrumKitOption>,
    drumKitFamilyNames: List<String>,
    onVolume: (Int, Float) -> Unit,
    onMute: (Int, Boolean) -> Unit,
    onSolo: (Int, Boolean) -> Unit,
    onProgram: (Int) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        // Part header: instrument name + ONE program picker for the whole part (iOS parity).
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(group.partName, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall)
            // Which CATALOG the picker offers follows the part: bank-128 kits for percussion, GM Level 1
            // patches otherwise — iOS `ProgramPicker(isDrums:)` splits the same way. A part with no
            // program at all (nothing selectable) still falls back to the plain label.
            val program = group.partProgram
            when {
                program == null ->
                    Text(stringResource(R.string.reader_mixer_drums), Modifier.weight(1.6f), style = MaterialTheme.typography.bodySmall)
                group.isDrums ->
                    DrumKitPickerButton(
                        program = program,
                        enabled = enabled,
                        kits = drumKits,
                        familyNames = drumKitFamilyNames,
                        modifier = Modifier.weight(1.6f),
                        onProgram = onProgram,
                    )
                else ->
                    ProgramPickerButton(program = program, enabled = enabled, gmInstruments = gmInstruments, modifier = Modifier.weight(1.6f), onProgram = onProgram)
            }
        }
        // Per-staff volume + Solo/Mute.
        group.channels.forEach { channel ->
            Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ResettableSlider(
                    value = channel.volume,
                    onValueChange = { onVolume(channel.staffIndex, it) },
                    // Default = the score's authored channel volume (CC7 → 0..1), seeded by the
                    // engine; double-tap restores it. Matches iOS PlaybackMixerModel.defaultVolume.
                    defaultValue = channel.defaultVolume,
                    onReset = { onVolume(channel.staffIndex, channel.defaultVolume) },
                    valueRange = 0f..1f,
                    enabled = enabled && !channel.effectiveMute,
                    modifier = Modifier.weight(1f).height(InspectorSliderHeight),
                )
                SmallToggle("S", channel.isSoloed, enabled, "Solo") { onSolo(channel.staffIndex, !channel.isSoloed) }
                SmallToggle("M", channel.isMuted, enabled, "Mute") { onMute(channel.staffIndex, !channel.isMuted) }
            }
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

/**
 * Percussion counterpart of [ProgramPickerButton]: picks a bank-128 KIT rather than a melodic patch, from
 * the shared `Domain.GMDrumKit` catalog loaded over JNI. Kits are grouped under their family name, as iOS
 * sections its drum-kit menu.
 *
 * An unrecognized stored program renders as `"Kit N"` — the same fallback iOS uses — so an override
 * written by a future SF2-split release still shows something meaningful instead of blanking the row.
 */
@Composable
private fun DrumKitPickerButton(
    program: Int,
    enabled: Boolean,
    kits: List<DrumKitOption>,
    familyNames: List<String>,
    modifier: Modifier = Modifier,
    onProgram: (Int) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val name = remember(program, kits) {
        kits.firstOrNull { it.program == program }?.displayName ?: "Kit $program"
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
            Icon(Icons.Default.ArrowDropDown, contentDescription = "Choose drum kit")
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            Column(
                Modifier
                    .heightIn(max = 320.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                // The catalog already arrives grouped (program order within family order), so a header
                // whenever the family index changes reproduces iOS's sections without re-sorting.
                var lastFamily = -1
                kits.forEach { kit ->
                    if (kit.familyIndex != lastFamily) {
                        lastFamily = kit.familyIndex
                        familyNames.getOrNull(kit.familyIndex)?.let { InspectorSectionHeader(it) }
                    }
                    DropdownMenuItem(
                        text = { Text(kit.displayName) },
                        onClick = {
                            onProgram(kit.program)
                            expanded = false
                        },
                    )
                }
            }
        }
    }
}
