# Android Settings & Inspectors — iOS Parity + Layout Polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align the Android Settings screen and the two Reader inspectors (display / playback) to iOS — uniform row heights, iOS row order / feature placement / wording, mixer "Parts" grouping — and fully localize the hardcoded labels.

**Architecture:** A shared single-line row scaffold (`InspectorRow` / `InspectorSliderRow`) plus a unified section header lives in the `FolinoReaderAndroid` library and is reused by both inspectors and (via the app→library dep) the Settings screen. Screens are recomposed to the iOS order; the mixer is regrouped by part; Version History becomes a nav destination; all literals move to `strings.xml`.

**Tech Stack:** Kotlin, Jetpack Compose, Material 3, DataStore, Android resource localization. Build via Gradle (`installDebug`) onto the **emulator** (`emulator-5554`).

**Worktree:** `.claude/worktrees/android-inspectors-ios-parity` (branch `worktree-android-inspectors-ios-parity`). All paths below are relative to that worktree root unless absolute.

**Spec:** `docs/superpowers/specs/2026-06-10-android-settings-inspectors-ios-parity-design.md`

---

## Build & Verify conventions (used by every task)

UI layout/wording cannot be unit-tested; the verification loop is build → emulator install → launch → look. Only pure logic (mixer grouping) gets a JVM unit test (Task 4).

- **Compile a library-module change:**
  `./Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
- **JVM unit test:**
  `./Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest`
- **Full install + launch (final + after risky tasks):**
  `./Android/gradlew -p Android :app:installDebug` then
  `adb -s emulator-5554 shell am start -n com.keynumber.folino/.MainActivity`
- If a fresh worktree fails to resolve generated wirelet/JNI symbols, run `Scripts/android-build-libs.sh` first (see memory: Android build toolchain). Do **not** disconnect the physical Pixel; target `emulator-5554` only.

Commit after each task with the message shown in its final step.

---

## File Structure

- **Create** `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ui/InspectorRows.kt` — shared scaffold (`InspectorRow`, `InspectorSliderRow`, `InspectorSectionHeader`, `CollapsibleHeader`, `InspectorRowMinHeight`).
- **Create** `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/MixerGrouping.kt` — pure part-grouping logic.
- **Create** `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/MixerGroupingTest.kt` — JVM test for the grouping.
- **Create** `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/VersionHistoryScreen.kt` — standalone version-history screen.
- **Modify** `DisplayInspectorSheet.kt`, `PlaybackInspectorSheet.kt`, `ReaderScreen.kt`, `SettingsScreen.kt`, `MainActivity.kt`.
- **Modify** `strings.xml` in `Android/app/src/main/res/values{,-ja,-ko,-zh-rCN,-zh-rTW}/` and `Android/FolinoReaderAndroid/src/main/res/values{,-ja,-ko,-zh-rCN,-zh-rTW}/`.

---

## Task 1: Shared layout scaffold

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ui/InspectorRows.kt`

- [ ] **Step 1: Write the scaffold file**

```kotlin
package com.keynumber.folino.reader.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp

/** Minimum height of a single-line inspector/settings row (Material one-line touch target). */
val InspectorRowMinHeight = 48.dp

/** Standard slider height shared by every slider-bearing row, so they read consistently. */
val InspectorSliderHeight = 24.dp

/**
 * A single-line control row with a uniform min height. Optional [leadingIcon], a [label] taking the
 * remaining width, and a [trailing] control slot. Every single-line control row (Switch, dropdown
 * trigger, +/- stepper, value+chevron) uses this so heights stay uniform across Settings and both
 * Reader inspectors. Pass [subtitle] for a two-line row (it grows taller; never forced to one line).
 * Pass [onClick] to make the whole row tappable (e.g. a chevron navigation row).
 */
@Composable
fun InspectorRow(
    label: String,
    modifier: Modifier = Modifier,
    leadingIcon: ImageVector? = null,
    leadingIconTint: Color? = null,
    subtitle: String? = null,
    onClick: (() -> Unit)? = null,
    trailing: @Composable () -> Unit = {},
) {
    val rowModifier = modifier
        .fillMaxWidth()
        .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
        .heightIn(min = InspectorRowMinHeight)
    Row(
        rowModifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (leadingIcon != null) {
            Icon(
                leadingIcon,
                contentDescription = null,
                tint = leadingIconTint ?: androidx.compose.material3.LocalContentColor.current,
            )
        }
        if (subtitle != null) {
            Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                Text(label, style = MaterialTheme.typography.bodyMedium)
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        }
        trailing()
    }
}

/**
 * A slider-bearing row — the documented exception to uniform single-line height. Optional
 * [leadingIcon], optional fixed-width [label], the [slider] slot (caller sets `Modifier.weight(1f)`
 * and `.height(InspectorSliderHeight)`), and an optional fixed-width [trailing] readout.
 */
@Composable
fun InspectorSliderRow(
    modifier: Modifier = Modifier,
    leadingIcon: ImageVector? = null,
    leadingIconTint: Color? = null,
    label: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    slider: @Composable () -> Unit,
) {
    Row(
        modifier.fillMaxWidth().heightIn(min = InspectorRowMinHeight),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (leadingIcon != null) {
            Icon(
                leadingIcon,
                contentDescription = null,
                tint = leadingIconTint ?: androidx.compose.material3.LocalContentColor.current,
            )
        }
        label?.invoke()
        slider()
        trailing?.invoke()
    }
}

/** Non-collapsible section header (Settings). */
@Composable
fun InspectorSectionHeader(title: String, modifier: Modifier = Modifier) {
    Text(
        title,
        modifier.fillMaxWidth().padding(top = 16.dp, bottom = 4.dp),
        style = MaterialTheme.typography.titleSmall,
    )
}

/** Collapsible section header (both Reader inspectors). Replaces the per-file copies. */
@Composable
fun CollapsibleHeader(title: String, expanded: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
        Icon(
            if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
            contentDescription = if (expanded) "Collapse" else "Expand",
        )
    }
}
```

- [ ] **Step 2: Compile**

Run: `./Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ui/InspectorRows.kt
git commit -m "feat(android-reader): shared inspector row scaffold for uniform layout"
```

---

## Task 2: Mixer part-grouping logic + test

This pure logic is needed by Task 6 (mixer restructure) and is the only unit-testable piece.

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/MixerGrouping.kt`
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/MixerGroupingTest.kt`

- [ ] **Step 1: Write the failing test**

```kotlin
package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MixerGroupingTest {
    private fun channel(staffIndex: Int, program: Int?) =
        MixerChannel(
            staffIndex = staffIndex,
            displayName = "S$staffIndex",
            program = program,
            volume = 1f,
            isMuted = false,
            isSoloed = false,
            effectiveMute = false,
        )

    @Test
    fun groupsChannelsByPartInPartThenStaffOrder() {
        // part 0 -> staff 0; part 1 -> staves 1,2
        val addresses = mapOf(
            0 to StaffAddress(partIndex = 0, staffIndexInPart = 0),
            1 to StaffAddress(partIndex = 1, staffIndexInPart = 0),
            2 to StaffAddress(partIndex = 1, staffIndexInPart = 1),
        )
        val channels = listOf(channel(2, 0), channel(0, 40), channel(1, 0))
        val parts = listOf("Violin", "Piano")

        val groups = groupMixerByPart(channels, addresses, parts)

        assertEquals(2, groups.size)
        assertEquals("Violin", groups[0].partName)
        assertEquals(listOf(0), groups[0].channels.map { it.staffIndex })
        assertEquals("Piano", groups[1].partName)
        assertEquals(listOf(1, 2), groups[1].channels.map { it.staffIndex })
    }

    @Test
    fun partProgramIsFirstChannelProgram() {
        val addresses = mapOf(0 to StaffAddress(0, 0), 1 to StaffAddress(0, 1))
        val channels = listOf(channel(0, 24), channel(1, 24))
        val groups = groupMixerByPart(channels, addresses, listOf("Guitar"))
        assertEquals(24, groups[0].partProgram)
    }

    @Test
    fun drumsPartHasNullProgram() {
        val addresses = mapOf(0 to StaffAddress(0, 0))
        val channels = listOf(channel(0, null))
        val groups = groupMixerByPart(channels, addresses, listOf("Drums"))
        assertNull(groups[0].partProgram)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "*.MixerGroupingTest"`
Expected: FAIL — `groupMixerByPart` / `PartMixerGroup` unresolved.

- [ ] **Step 3: Write the implementation**

```kotlin
package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel

/**
 * One part's slice of the flat mixer: its display name, the staff channels that belong to it (in
 * staff-in-part order), and the part-level program (the first channel's program; null = drums).
 */
data class PartMixerGroup(
    val partIndex: Int,
    val partName: String,
    val partProgram: Int?,
    val channels: List<MixerChannel>,
)

/**
 * Regroup the engine's flat [channels] into per-part groups, mirroring the iOS playback inspector's
 * "Parts" section. [staffAddressByIndex] maps a channel's flat `staffIndex` to its positional
 * [StaffAddress] (part + staff-in-part); [partNames] supplies each part's display name by index.
 * Channels with no resolvable address are dropped. Within a part, channels are ordered by
 * staff-in-part; parts are ordered by part index. The part program is the first channel's program.
 */
fun groupMixerByPart(
    channels: List<MixerChannel>,
    staffAddressByIndex: Map<Int, StaffAddress>,
    partNames: List<String>,
): List<PartMixerGroup> {
    val byPart = channels
        .mapNotNull { ch -> staffAddressByIndex[ch.staffIndex]?.let { addr -> addr to ch } }
        .groupBy { it.first.partIndex }
    return byPart.keys.sorted().map { partIndex ->
        val ordered = byPart.getValue(partIndex)
            .sortedBy { it.first.staffIndexInPart }
            .map { it.second }
        PartMixerGroup(
            partIndex = partIndex,
            partName = partNames.getOrNull(partIndex)?.takeIf { it.isNotEmpty() }
                ?: "Part ${partIndex + 1}",
            partProgram = ordered.firstOrNull()?.program,
            channels = ordered,
        )
    }
}
```

Note: verify `MixerChannel`'s constructor parameter names against
`io.github.jiyimeta.sheetmusic.audio.model.MixerChannel` before running; adjust the test's
`channel()` helper to the real field names if they differ (the production code does not construct
`MixerChannel`, so only the test must match).

- [ ] **Step 4: Run test to verify it passes**

Run: `./Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "*.MixerGroupingTest"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/MixerGrouping.kt Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/MixerGroupingTest.kt
git commit -m "feat(android-reader): part-grouping logic for the mixer (iOS Parts parity)"
```

---

## Task 3: Display inspector — adopt scaffold, add Transpose, reorder

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/DisplayInspectorSheet.kt`

Target General order: Display mode → Staff size → **Transpose (new)** → Follow breaks → Collapse rests → Show hidden → Show seek bar.

- [ ] **Step 1: Add transpose params to `DisplayInspectorSheet`**

Add to the parameter list (after `onShowSeekBarChange`):

```kotlin
    /** Current per-score transpose value in semitones (−7..7). */
    transposeSemitones: Int = 0,
    /** Persists the per-score transpose value. Persist-only on Android (no transpose effect yet). */
    onTransposeChange: (Int) -> Unit = {},
```

- [ ] **Step 2: Insert the Transpose row and adopt scaffold in the General block**

In the `if (generalExpanded) { ... }` block, the item order becomes (replace the block):

```kotlin
            if (generalExpanded) {
                item { LayoutModeRow(options.mode) { onChange(options.copy(mode = it)) } }
                item { StaffSizeRow(options.staffSize) { onChange(options.copy(staffSize = it)) } }
                item {
                    TransposeRow(
                        semitones = transposeSemitones,
                        enabled = true,
                        onChange = onTransposeChange,
                        showLeadingIcon = false,
                    )
                }
                item {
                    SwitchRow(
                        label = stringResource(R.string.reader_pref_honor_breaks),
                        checked = options.honorLayoutBreaks,
                    ) { onChange(options.copy(honorLayoutBreaks = it)) }
                }
                item {
                    SwitchRow(
                        label = stringResource(R.string.reader_pref_collapse_rests),
                        checked = options.collapseMultiMeasureRests,
                    ) { onChange(options.copy(collapseMultiMeasureRests = it)) }
                }
                item {
                    SwitchRow(
                        label = stringResource(R.string.reader_pref_show_invisible),
                        checked = options.showInvisibleElements,
                    ) { onChange(options.copy(showInvisibleElements = it)) }
                }
                item {
                    SwitchRow(
                        label = stringResource(R.string.reader_pref_show_seek_bar),
                        checked = showSeekBar,
                    ) { onShowSeekBarChange(it) }
                }
            }
```

`TransposeRow` is defined in `PlaybackInspectorSheet.kt`. In Step 3 it gains a `showLeadingIcon`
param and moves to the shared file so both inspectors use one copy.

- [ ] **Step 3: Move `TransposeRow` to the shared scaffold file and add `showLeadingIcon`**

Cut `TransposeRow` from `PlaybackInspectorSheet.kt`, paste into `InspectorRows.kt` (make it
`internal`/public, same package family `com.keynumber.folino.reader` — keep it in
`PlaybackInspectorSheet.kt`'s package; simplest is to leave it in a shared
`com/keynumber/folino/reader/InspectorControls.kt` file). Add the `showLeadingIcon` param and
build the row via `InspectorRow`:

```kotlin
@Composable
internal fun TransposeRow(
    semitones: Int,
    enabled: Boolean,
    onChange: (Int) -> Unit,
    showLeadingIcon: Boolean = true,
) {
    val signedReadout = if (semitones > 0) "+$semitones" else "$semitones"
    InspectorRow(
        label = stringResource(R.string.reader_inspector_transpose),
        leadingIcon = if (showLeadingIcon) Icons.Default.SwapVert else null,
        leadingIconTint = if (showLeadingIcon) MaterialTheme.colorScheme.primary else null,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = signedReadout,
                modifier = Modifier.clickable(enabled = enabled) { onChange(0) }.padding(horizontal = 4.dp),
                style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
            )
            IconButton(
                onClick = { onChange((semitones - 1).coerceAtLeast(-7)) },
                enabled = enabled && semitones > -7,
                modifier = Modifier.size(32.dp),
            ) { Icon(Icons.Default.Remove, contentDescription = stringResource(R.string.reader_transpose_down), modifier = Modifier.size(16.dp)) }
            IconButton(
                onClick = { onChange((semitones + 1).coerceAtMost(7)) },
                enabled = enabled && semitones < 7,
                modifier = Modifier.size(32.dp),
            ) { Icon(Icons.Default.Add, contentDescription = stringResource(R.string.reader_transpose_up), modifier = Modifier.size(16.dp)) }
        }
    }
}
```

(`reader_transpose_down` / `reader_transpose_up` strings are added in Task 8; replacing the prior
hardcoded "Transpose down"/"Transpose up" content descriptions.)

- [ ] **Step 4: Convert `SwitchRow`, `LayoutModeRow`, `StaffSizeRow` to the scaffold**

- `SwitchRow` body becomes `InspectorRow(label = label) { Switch(checked = checked, onCheckedChange = onCheckedChange) }`.
- `LayoutModeRow` becomes `InspectorRow(label = stringResource(R.string.reader_display_mode)) { <existing Box+dropdown trigger> }` (no leading icon — visual inspector has none).
- `StaffSizeRow` becomes an `InspectorSliderRow` with `label = { Text(stringResource(R.string.reader_pref_staff_size), Modifier.width(88.dp), maxLines = 1, overflow = Ellipsis, style = bodyMedium) }`, the existing `Slider(... Modifier.weight(1f).height(InspectorSliderHeight))`, and `trailing = { Text("${staffSize.roundToInt()} pt", Modifier.width(44.dp), ...) }`.
- Delete the now-unused local `CollapsibleHeader` (use the shared one) and the local `sliderHeight` (use `InspectorSliderHeight`). Update the `CollapsibleHeader(...)` call sites — signature is unchanged.

- [ ] **Step 5: Compile**

Run: `./Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/
git commit -m "feat(android-reader): display inspector adopts scaffold + adds Transpose (iOS parity)"
```

---

## Task 4: Playback inspector — General reorder, Tempo two-line, Playlist row, scaffold

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt`

Target General order: Metronome → Tempo → Repeat → Playlist (if `isInPlaylist`) → Volume → Transpose → Calibration(A4).

- [ ] **Step 1: Add params for playlist context to `PlaybackInspectorSheet`**

Add to the parameter list:

```kotlin
    /** True when the Reader was opened from a playlist — gates the continuation row (iOS parity). */
    isInPlaylist: Boolean = false,
    /** Current global playlist-continuation mode wire ("off" | "playThrough" | "loopPlaylist"). */
    continuationModeWire: String = "playThrough",
    /** Persists the global continuation mode. */
    onContinuationModeChange: (String) -> Unit = {},
    /** Part display names by part index, for the mixer "Parts" grouping. */
    partNames: List<String> = emptyList(),
```

- [ ] **Step 2: Reorder the General block to the iOS order**

Replace the `if (generalExpanded) { ... }` items with this exact order. Each row uses the scaffold;
leading icons stay (iOS playback rows have icons). Metronome / Repeat rows become `InspectorRow`:

```kotlin
            if (generalExpanded) {
                item {
                    InspectorRow(
                        label = stringResource(R.string.reader_playback_metronome),
                        leadingIcon = Icons.Default.Timer,
                    ) {
                        Switch(checked = metronomeEnabled, onCheckedChange = onMetronomeChange, enabled = controlsEnabled)
                    }
                }
                item { TempoRow(openingQuarterBpm = openingQuarterBpm, rate = rate, enabled = controlsEnabled,
                    onRate = { engine?.setRate(it); onPersistTempoMultiplier(it.toDouble()) }) }
                item {
                    InspectorRow(
                        label = stringResource(R.string.reader_repeat_label),
                        leadingIcon = Icons.Default.Repeat,
                    ) { RepeatModePicker(selected = repeatMode, enabled = controlsEnabled, onSelect = { audioVm.setRepeatMode(it) }) }
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
                        label = { Text(stringResource(R.string.reader_playback_volume), Modifier.width(76.dp), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium) },
                        trailing = { Text("${(masterVolume * 100).toInt()}%", Modifier.width(64.dp), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall) },
                    ) {
                        Slider(value = masterVolume, onValueChange = { audioVm.setMasterVolume(it); onPersistMasterVolume(it.toDouble()) },
                            valueRange = 0f..1f, enabled = controlsEnabled, modifier = Modifier.weight(1f).height(InspectorSliderHeight))
                    }
                }
                item { TransposeRow(semitones = transposeSemitones, enabled = controlsEnabled, onChange = onTransposeChange) }
                item {
                    A4ReferenceRow(
                        hz = a4ReferenceHz, globalHz = globalA4ReferenceHz, enabled = controlsEnabled,
                        onValueChange = { audioVm.setA4ReferenceHz(it.toDouble()) },
                        onValueChangeFinished = { val s = snapA4Hz(a4ReferenceHz); audioVm.setA4ReferenceHz(s); onPersistA4ReferenceHz(s) },
                        onStep = { d -> val n = (a4ReferenceHz + d).coerceIn(415.0, 466.0); audioVm.setA4ReferenceHz(n); onPersistA4ReferenceHz(n) },
                    )
                }
            }
```

Verify the exact enum constant for "off" (`RepeatMode.OFF` vs `RepeatMode.Off`) against `RepeatMode`
in this module before compiling.

- [ ] **Step 3: Replace the old `IconSliderRow`-based Volume/Tempo and add `TempoRow` (two-line)**

Delete the `IconSliderRow` composable (Volume now uses `InspectorSliderRow`; Tempo uses the new
`TempoRow`). Add `TempoRow` mirroring the iOS two-line design (glyph marking + ± stepper / percent +
slider). The Android engine exposes only the multiplier (`rate`) and `openingQuarterBpm`; use the
quarter-note glyph `♩` (no governing-tempo glyph available on Android — note this in a comment):

```kotlin
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
    InspectorSliderRow(leadingIcon = Icons.Default.Speed, leadingIconTint = MaterialTheme.colorScheme.primary) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            // Top line: engraved-style marking (quarter-note glyph + BPM, tap to reset) + ± stepper.
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = "♩ = $bpm",
                    modifier = Modifier.weight(1f).clickable(enabled = enabled) { onRate(1.0f) },
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                )
                IconButton(onClick = { onRate(((bpm - 1) / openingQuarterBpm).toFloat().coerceIn(minRate, maxRate)) },
                    enabled = enabled && rate > minRate, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Remove, contentDescription = stringResource(R.string.reader_tempo_decrease), modifier = Modifier.size(16.dp))
                }
                IconButton(onClick = { onRate(((bpm + 1) / openingQuarterBpm).toFloat().coerceIn(minRate, maxRate)) },
                    enabled = enabled && rate < maxRate, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Add, contentDescription = stringResource(R.string.reader_tempo_increase), modifier = Modifier.size(16.dp))
                }
            }
            // Bottom line: percent readout + multiplier slider.
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("$percent%", Modifier.width(44.dp), style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace), color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                Slider(value = rate, onValueChange = onRate, valueRange = minRate..maxRate, enabled = enabled, modifier = Modifier.weight(1f).height(InspectorSliderHeight))
            }
        }
    }
}
```

- [ ] **Step 4: Add `ContinuationRow`**

```kotlin
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
            leadingIconTint = MaterialTheme.colorScheme.primary,
        ) {
            var expanded by remember { mutableStateOf(false) }
            val current = modes.firstOrNull { it.first == modeWire } ?: modes[1]
            Box {
                Row(Modifier.clickable(enabled = enabled && !repeatActive) { expanded = true }.padding(horizontal = 4.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(current.second, color = if (repeatActive) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
                    Icon(Icons.Default.UnfoldMore, contentDescription = null, modifier = Modifier.size(16.dp))
                }
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    modes.forEach { (raw, label) ->
                        DropdownMenuItem(text = { Text(label) },
                            trailingIcon = if (raw == modeWire) { { Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp)) } } else null,
                            onClick = { onSelect(raw); expanded = false })
                    }
                }
            }
        }
        if (repeatActive) {
            Text(stringResource(R.string.reader_continuation_repeat_active), Modifier.padding(start = 32.dp, bottom = 4.dp),
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
```

- [ ] **Step 5: Delete the local `CollapsibleHeader` and `sliderHeight`; use the shared ones**

Remove the private `CollapsibleHeader` and `private val sliderHeight` from this file; the call sites
use the shared `CollapsibleHeader` and `InspectorSliderHeight`. (`MixerRow`'s slider also switches to
`InspectorSliderHeight` — handled in Task 5.)

- [ ] **Step 6: Compile**

Run: `./Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 7: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt
git commit -m "feat(android-reader): playback inspector iOS order + two-line Tempo + Playlist row"
```

---

## Task 5: Mixer → "Parts" grouped section

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt`

- [ ] **Step 1: Replace the flat Mixer section with a part-grouped "Parts" section**

Change the header to the localized "Parts" string and iterate `groupMixerByPart(...)`:

```kotlin
            item { CollapsibleHeader(stringResource(R.string.reader_inspector_parts), mixerExpanded) { mixerExpanded = !mixerExpanded } }
            if (mixerExpanded) {
                val groups = groupMixerByPart(mixerChannels, staffAddressByIndex.mapKeys { it.key }, partNames)
                if (groups.isEmpty()) {
                    item { Text(stringResource(R.string.reader_mixer_empty), Modifier.padding(vertical = 4.dp)) }
                } else {
                    groups.forEach { group ->
                        item(key = "part-${group.partIndex}") {
                            PartMixerSection(
                                group = group,
                                enabled = controlsEnabled,
                                gmInstruments = gmInstruments,
                                staffAddressByIndex = staffAddressByIndex,
                                onVolume = { idx, v -> engine?.setStaffVolume(idx, v); staffAddressByIndex[idx]?.let { onPersistStaffVolume(it, v) } },
                                onMute = { idx, m -> engine?.setStaffMuted(idx, m) },
                                onSolo = { idx, s -> engine?.setStaffSoloed(idx, s) },
                                onProgram = { program ->
                                    group.channels.forEach { ch ->
                                        engine?.setStaffProgram(ch.staffIndex, program)
                                        staffAddressByIndex[ch.staffIndex]?.let { onPersistStaffProgram(it, program) }
                                    }
                                },
                            )
                            HorizontalDivider(Modifier.padding(top = 2.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                        }
                    }
                }
            }
```

Note: `staffAddressByIndex.mapKeys { it.key }` is an identity copy — pass `staffAddressByIndex`
directly; the `Map<Int, StaffAddress>` type already matches `groupMixerByPart`'s parameter.

- [ ] **Step 2: Add `PartMixerSection` (part header + per-staff rows)**

```kotlin
@Composable
private fun PartMixerSection(
    group: PartMixerGroup,
    enabled: Boolean,
    gmInstruments: List<GMInstrument>,
    staffAddressByIndex: Map<Int, StaffAddress>,
    onVolume: (Int, Float) -> Unit,
    onMute: (Int, Boolean) -> Unit,
    onSolo: (Int, Boolean) -> Unit,
    onProgram: (Int) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        // Part header: instrument name + one program picker for the whole part (iOS parity).
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(group.partName, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall)
            val program = group.partProgram
            if (program != null) {
                ProgramPickerButton(program = program, enabled = enabled, gmInstruments = gmInstruments, modifier = Modifier.weight(1.6f), onProgram = onProgram)
            } else {
                Text(stringResource(R.string.reader_mixer_drums), Modifier.weight(1.6f), style = MaterialTheme.typography.bodySmall)
            }
        }
        // Per-staff volume + Solo/Mute.
        group.channels.forEach { channel ->
            Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Slider(value = channel.volume, onValueChange = { onVolume(channel.staffIndex, it) }, valueRange = 0f..1f,
                    enabled = enabled && !channel.effectiveMute, modifier = Modifier.weight(1f).height(InspectorSliderHeight))
                SmallToggle("S", channel.isSoloed, enabled, "Solo") { onSolo(channel.staffIndex, !channel.isSoloed) }
                SmallToggle("M", channel.isMuted, enabled, "Mute") { onMute(channel.staffIndex, !channel.isMuted) }
            }
        }
    }
}
```

Delete the old `MixerRow` composable (its responsibilities are now split between `PartMixerSection`
and the part header). Keep `SmallToggle` and `ProgramPickerButton`.

- [ ] **Step 3: Compile**

Run: `./Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt
git commit -m "feat(android-reader): mixer regrouped into per-part Parts section (iOS parity)"
```

---

## Task 6: ReaderScreen wiring

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`

- [ ] **Step 1: Pass transpose to the display inspector**

At the `DisplayInspectorSheet(...)` call (~line 398), add:

```kotlin
            transposeSemitones = transposeSemitones,
            onTransposeChange = onTransposeChange,
```

(`transposeSemitones` and `onTransposeChange` already exist at this scope — they are forwarded to
the playback inspector. Reuse the same values.)

- [ ] **Step 2: Pass parts + playlist context to the playback inspector**

At the `PlaybackInspectorSheet(...)` call (~line 379), add:

```kotlin
            partNames = mixerParts.map { it.name },
            isInPlaylist = isInPlaylist,
            continuationModeWire = continuationModeWire,
            onContinuationModeChange = onContinuationModeChange,
```

- [ ] **Step 3: Add the new params to `ReaderScreen`**

Add to `ReaderScreen`'s parameter list:

```kotlin
    isInPlaylist: Boolean = false,
    continuationModeWire: String = "playThrough",
    onContinuationModeChange: (String) -> Unit = {},
```

`mixerParts` already exists (`val mixerParts by readerVm.parts.collectAsStateWithLifecycle()`); its
`PartDescriptor.name` supplies `partNames`. (Confirm `PartDescriptor` exposes `name`; it does — see
`DisplayInspectorSheet.PartRow`.)

- [ ] **Step 4: Compile**

Run: `./Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(android-reader): wire transpose/parts/playlist context into inspectors"
```

---

## Task 7: ReaderScreen caller — supply playlist context

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (and/or wherever
  `ReaderScreen(...)` is invoked — grep `ReaderScreen(` in `Android/app`).

- [ ] **Step 1: Locate the ReaderScreen invocation and the open-reader route**

Run: `git -C <worktree> grep -n "ReaderScreen(\|openReader\|navigate(\"reader" -- 'Android/app'`
Determine whether the reader was opened from a playlist (a playlist id / origin in the nav route or
the open-info). If the origin is available, pass `isInPlaylist = true` for that path; otherwise pass
`false`.

- [ ] **Step 2: Wire `isInPlaylist` + continuation prefs into the `ReaderScreen` call**

Pass:

```kotlin
                isInPlaylist = openedFromPlaylist,   // derived in Step 1; false if no playlist origin
                continuationModeWire = continuationModeWire,   // collectAsState from SettingsPrefs.playlistContinuationMode
                onContinuationModeChange = { scope.launch { prefs.setPlaylistContinuationMode(it) } },
```

Add the `continuationModeWire` collected state near the other prefs collection in the reader host
(`val continuationModeWire by prefs.playlistContinuationMode.collectAsState(initial = "playThrough")`).
If `SettingsPrefs`/`prefs` is not already in scope at the reader host, thread it the same way the
other reader prefs reach this composable.

Note: if the open-reader path genuinely has no playlist origin today, `isInPlaylist` stays `false`
and the continuation row never shows — that is the correct, safe outcome (continuous playback is not
yet implemented on Android; this only wires the gate). Record that in the commit body.

- [ ] **Step 3: Compile the app module**

Run: `./Android/gradlew -p Android :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android): supply playlist context + continuation prefs to the Reader"
```

---

## Task 8: Settings screen — reorder, new rows, scaffold, Default Calibration

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt`

Target Reader-section order: Metronome → PiP(+footer) → Collapse rests → **Show hidden(new)** →
Keep awake(+footer, iOS wording) → **Show seek bar(new)** → Repeat → Playlist → **Default
Calibration** → **Display mode (renamed, moved here)** → High quality audio. Then a section footer.

- [ ] **Step 1: Collect the two existing prefs and add `onOpenVersionHistory`**

In `SettingsScreen`, add collected state:

```kotlin
    val showInvisible by prefs.showInvisible.collectAsState(initial = false)
    val showSeekBar by prefs.showSeekBar.collectAsState(initial = true)
```

Add a parameter:

```kotlin
    onOpenVersionHistory: (() -> Unit)? = null,
```

- [ ] **Step 2: Recompose the Reader section to the target order**

Reuse the existing `ToggleRow`/dropdown helpers but in the new order; add the two new toggles, the
footer, the PiP/keep-awake subtitles, and rename. Replace the Reader-section items with:

```kotlin
        item { InspectorSectionHeader(stringResource(R.string.settings_section_reader)) }
        item { ToggleRow(Icons.Filled.MusicNote, stringResource(R.string.settings_reader_metronome), metronome) { v -> scope.launch { prefs.setMetronome(v) } } }
        item { ToggleRow(Icons.Filled.PictureInPicture, stringResource(R.string.settings_reader_pip), pip, subtitle = stringResource(R.string.settings_reader_pip_footer)) { v -> scope.launch { prefs.setPip(v) } } }
        item { ToggleRow(Icons.Filled.UnfoldLess, stringResource(R.string.settings_reader_collapse_rests), collapse) { v -> scope.launch { prefs.setCollapseRests(v) } } }
        item { ToggleRow(Icons.Filled.Visibility, stringResource(R.string.settings_reader_show_invisible), showInvisible) { v -> scope.launch { prefs.setShowInvisible(v) } } }
        item { ToggleRow(Icons.Filled.ScreenLockPortrait, stringResource(R.string.settings_reader_keep_awake), keepAwake, subtitle = stringResource(R.string.settings_reader_keep_awake_footer)) { v -> scope.launch { prefs.setKeepAwake(v) } } }
        item { ToggleRow(Icons.Filled.Timeline, stringResource(R.string.settings_reader_show_seek_bar), showSeekBar) { v -> scope.launch { prefs.setShowSeekBar(v) } } }
        item { /* Repeat row — unchanged, label -> stringResource(R.string.settings_reader_repeat) */ }
        item { /* Playlist row — unchanged */ }
        item { A4SliderRow(hz = a4Hz, onValueChange = ..., onValueChangeFinished = ...) }   // restructured in Step 3
        item { /* Display mode dropdown — moved here; label -> stringResource(R.string.settings_reader_display_mode) */ }
        item { SoundfontRow(...) }   // title -> stringResource(R.string.settings_reader_high_quality_audio)
        item { Text(stringResource(R.string.settings_reader_continuation_footer), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
```

Keep the existing Repeat / Playlist / Display-mode (dropdown) composable bodies — only their label
strings change to resources and the Display-mode block moves below `A4SliderRow`. Use
`Icons.Filled.Timeline` for the seek-bar row and `Icons.Filled.Visibility` for show-hidden (closest
Material analogues to the iOS SF Symbols).

Convert the `ToggleRow` helper's body to the shared `InspectorRow` (so settings rows match the
inspectors): `InspectorRow(label = title, leadingIcon = icon, subtitle = subtitle) { Switch(checked = checked, onCheckedChange = onChange) }`.

- [ ] **Step 3: Restructure `A4SliderRow` to "Default Calibration" (iOS layout)**

```kotlin
@Composable
private fun A4SliderRow(hz: Double, onValueChange: (Float) -> Unit, onValueChangeFinished: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Filled.MusicNote, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Text(stringResource(R.string.settings_a4_reference), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            Text("A4 = ${hz.roundToInt()}Hz", style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace))
        }
        Text(stringResource(R.string.reader_settings_a4_description), Modifier.padding(start = 32.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Slider(value = hz.toFloat(), onValueChange = onValueChange, onValueChangeFinished = onValueChangeFinished, valueRange = 415f..466f, modifier = Modifier.fillMaxWidth())
    }
}
```

`settings_a4_reference`'s value changes from the old content-description usage to the iOS title
"Default Calibration" (Task 8 strings). Keep the existing snap-on-release logic in the call site.

- [ ] **Step 4: Move Version History into the About section as a nav row**

Delete the standalone `if (versionHistory.isNotEmpty()) { ... }` inline section. In the About
section (the `if (onOpenLicenses != null)` block), add a Version History row **before** Licenses,
shown when `onOpenVersionHistory != null`:

```kotlin
            if (onOpenVersionHistory != null) {
                item {
                    InspectorRow(label = stringResource(R.string.settings_version_history), leadingIcon = Icons.Filled.History, onClick = onOpenVersionHistory) {
                        Icon(Icons.AutoMirrored.Filled.ArrowForwardIos, contentDescription = null)
                    }
                }
            }
```

Convert the Licenses and Send Feedback rows to `InspectorRow` as well (label from resources). Use
`InspectorSectionHeader` for the "About" and "Privacy" headers.

- [ ] **Step 5: Compile the app module**

Run: `./Android/gradlew -p Android :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt
git commit -m "feat(android): settings screen iOS order/wording + scaffold + Default Calibration"
```

---

## Task 9: Version History standalone screen + host nav

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/VersionHistoryScreen.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Create the screen**

```kotlin
package com.keynumber.folino.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** Standalone version-history screen (Android parity with the iOS NavigationLink destination). */
@Composable
fun VersionHistoryScreen(items: List<VersionHistoryItem>) {
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        items(items.size) { idx ->
            val v = items[idx]
            Column {
                Text(v.version, style = MaterialTheme.typography.titleMedium)
                v.descriptions.forEach { Text("• $it", style = MaterialTheme.typography.bodyMedium) }
            }
        }
    }
}
```

- [ ] **Step 2: Wire the nav destination in MainActivity**

At the `SettingsScreen(prefs, versionItems, onOpenLicenses = ...)` call (~line 688), add
`onOpenVersionHistory = { nav.navigate("versionHistory") }`. Add a `composable("versionHistory")`
route (mirroring the `"licenses"` route) that wraps `VersionHistoryScreen(versionItems)` in whatever
`Scaffold`/`TopAppBar` the licenses route uses, titled from `R.string.settings_version_history`.

Also pass `onOpenVersionHistory` down through the intermediate composables that currently forward
`onOpenLicenses` (the function at ~line 647/671 takes `onOpenLicenses: () -> Unit`; add a parallel
`onOpenVersionHistory: () -> Unit`).

- [ ] **Step 3: Compile the app module**

Run: `./Android/gradlew -p Android :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/VersionHistoryScreen.kt Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android): version history as a separate screen (iOS nav parity)"
```

---

## Task 10: Localization — strings.xml across all locales

All new string keys must be added to **five** files per module: `values/`, `values-ja/`,
`values-ko/`, `values-zh-rCN/`, `values-zh-rTW/`. Provide EN + JA inline (below); copy ko / zh-rCN /
zh-rTW from the iOS String Catalog entry named in the "iOS key" column (open the iOS `.xcstrings`,
find that key, copy its `ko` / `zh-Hans` / `zh-Hant` localizations). For keys with **no** iOS
counterpart (none below — every row maps to an iOS string), translate manually.

iOS catalogs:
- Settings: `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`
- Reader: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`

### App module — `Android/app/src/main/res/values*/strings.xml`

| Android key | EN | JA | iOS key |
|---|---|---|---|
| `settings_section_reader` | Reader | Reader | (iOS section header is implicit; use "Reader"/"Reader") |
| `settings_reader_metronome` | Metronome | メトロノーム | settings.reader.metronome |
| `settings_reader_pip` | Picture in Picture | ピクチャインピクチャ | settings.reader.pictureInPicture |
| `settings_reader_pip_footer` | (iOS footer text) | (iOS footer ja) | settings.reader.pictureInPicture.footer |
| `settings_reader_collapse_rests` | Collapse multi-measure rests | 複数小節休符をまとめる | settings.reader.collapseMultiMeasureRests |
| `settings_reader_show_invisible` | Show hidden elements | 非表示要素を表示 | settings.reader.showInvisibleElements |
| `settings_reader_keep_awake` | Prevent auto-lock | 自動ロックを抑止 | settings.reader.keepScreenAwake |
| `settings_reader_keep_awake_footer` | (iOS footer) | (iOS footer ja) | settings.reader.keepScreenAwake.footer |
| `settings_reader_show_seek_bar` | Show seek bar | シークバー表示 | settings.reader.showSeekBar |
| `settings_reader_repeat` | Repeat | リピート | settings.reader.repeat |
| `settings_reader_display_mode` | Display mode | 表示モード | settings.reader.layout.title |
| `settings_reader_high_quality_audio` | High quality audio | 高品質音源 (206MB) | settings.soundfont.highQuality.title |
| `settings_reader_continuation_footer` | (iOS footer) | (iOS footer ja) | settings.reader.continuation.footer |
| `settings_version_history` | Version History | アップデート履歴 | settings.versionHistory.title |
| `settings_about_title` | About | 情報 | settings.about.title |
| `settings_about_licenses` | Licenses | ライセンス | settings.about.licenses |
| `settings_about_send_feedback` | Send Feedback | フィードバックを送る | settings.about.sendFeedback |

Reuse the **existing** Android keys where they already exist and match (`settings_privacy_title`,
`settings_privacy_crash_title/description`, `settings_playlist_continuation`,
`playlist_continuation_*`, `settings_a4_reference`, `reader_settings_a4_description`). Change
`settings_a4_reference`'s value to "Default Calibration" / "既定キャリブレーション" (iOS
`settings.playback.a4Reference.title`) since it is now the row title.

Also localize the SoundFont dialog literals currently hardcoded in `SoundfontRow` ("No Wi-Fi",
"Download over cellular", "Wait for Wi-Fi", "Delete download", "Delete", "Cancel", "Downloading… %",
"Download now", "High-fidelity instruments (≈206 MB)", "Waiting for Wi-Fi") and the feedback Toast
"No email app found" — add keys and replace literals.

### Reader module — `Android/FolinoReaderAndroid/src/main/res/values*/strings.xml`

| Android key | EN | JA | iOS key |
|---|---|---|---|
| `reader_playback_metronome` | Metronome | メトロノーム | reader.inspector.metronome |
| `reader_playback_volume` | Volume | 音量 | reader.inspector.masterVolume |
| `reader_inspector_continuation` | Playlist | プレイリスト | reader.inspector.continuation |
| `reader_continuation_off` | Off | オフ | reader.inspector.continuation.off |
| `reader_continuation_play_through` | Continuous | 連続再生 | reader.inspector.continuation.playThrough |
| `reader_continuation_loop` | Repeat All | 全曲リピート | reader.inspector.continuation.loopPlaylist |
| `reader_continuation_repeat_active` | Looping this score — playback won't move to the next. | この楽譜をリピート中のため、次の楽譜へは進みません。 | reader.inspector.continuation.repeatActive |
| `reader_mixer_empty` | No parts to mix. | ミックスするパートがありません。 | (no iOS string; translate — JA as shown) |
| `reader_mixer_drums` | Drums | ドラム | (no iOS string; translate — JA as shown) |
| `reader_tempo_decrease` | Decrease tempo | テンポを下げる | (a11y; no iOS string; translate) |
| `reader_tempo_increase` | Increase tempo | テンポを上げる | (a11y; no iOS string; translate) |
| `reader_transpose_down` | Transpose down | 移調を下げる | (a11y; no iOS string; translate) |
| `reader_transpose_up` | Transpose up | 移調を上げる | (a11y; no iOS string; translate) |

Reuse existing reader keys (`reader_inspector_general`, `reader_inspector_parts`,
`reader_display_mode`, `reader_layout_*`, `reader_pref_*`, `reader_repeat_*`,
`reader_inspector_transpose`, `reader_clef_*`, `reader_playback_a4_*`). The "General" /
"Parts" headers already have keys (`reader_inspector_general` / `reader_inspector_parts`) — use them
in the playback inspector instead of the hardcoded `"General"`/`"Mixer"`. Replace `"Tempo"` with a
new `reader_playback_tempo` (EN "Tempo" / JA "テンポ") only if a visible label is needed; the
two-line `TempoRow` shows the glyph marking, not a text label, so no "Tempo" string is required.

- [ ] **Step 1:** Add all new keys to `Android/app/.../values/strings.xml`, then `values-ja`,
  `values-ko`, `values-zh-rCN`, `values-zh-rTW` (copy ko/zh from the iOS catalog by the mapped key).
- [ ] **Step 2:** Add all new keys to the five `FolinoReaderAndroid` `strings.xml` files.
- [ ] **Step 3:** Replace every hardcoded literal in `SettingsScreen.kt`, `DisplayInspectorSheet.kt`,
  `PlaybackInspectorSheet.kt`, `InspectorRows.kt`/control files with `stringResource(...)` (the
  "Collapse"/"Expand" content descriptions in `CollapsibleHeader` too — add `reader_section_collapse`
  / `reader_section_expand`).
- [ ] **Step 4: Compile both modules**

Run: `./Android/gradlew -p Android :app:compileDebugKotlin :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL (a missing key surfaces as an unresolved `R.string.*`).

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/main/res Android/FolinoReaderAndroid/src/main/res Android/app/src/main/kotlin Android/FolinoReaderAndroid/src/main/kotlin
git commit -m "i18n(android): localize settings/inspector labels mirroring iOS wording (en/ja/ko/zh)"
```

---

## Task 11: Build, install, and verify on the emulator

**Files:** none (verification only).

- [ ] **Step 1: Full build + install**

Run: `./Android/gradlew -p Android :app:installDebug`
Expected: BUILD SUCCESSFUL, app installed on `emulator-5554`. If JNI/wirelet symbols fail to
resolve, run `Scripts/android-build-libs.sh` first, then re-install.

- [ ] **Step 2: Launch**

Run: `adb -s emulator-5554 shell am start -n com.keynumber.folino/.MainActivity`

- [ ] **Step 3: Visual verification checklist** (screenshot each; confirm against the spec)

- Settings: single-line rows (Metronome … Show seek bar, Repeat, Playlist, Display mode) render at
  uniform height; PiP / Keep-awake / crash-reporting two-line rows taller; Default Calibration shows
  title + "A4 = NNNHz" readout + description + slider; row order matches the spec table; About has
  Version History → Licenses → Send Feedback; tapping Version History pushes its own screen.
- Display inspector: order Display mode → Staff size → Transpose → Follow breaks → Collapse → Show
  hidden → Show seek bar; no leading icons on General rows; uniform heights; Parts unchanged.
- Playback inspector: order Metronome → Tempo (two-line: glyph+BPM+stepper / %+slider) → Repeat →
  (Playlist only if opened from a playlist) → Volume → Transpose → Calibration; "Parts" section
  groups staves under each part with one program picker per part; multi-staff part (e.g. Piano)
  shows two volume rows under one header.
- Functional: toggle Show hidden / Show seek bar → Reader reflects them; A4 snaps to 432/440;
  Transpose persists and appears in both inspectors; changing a part's program updates all its
  staves.

- [ ] **Step 4: Locale check**

Set the emulator to Japanese: `adb -s emulator-5554 shell am start -a android.settings.LOCALE_SETTINGS`
(or via Settings UI), relaunch the app, and confirm the mirrored Japanese wording appears on all
three screens. Revert the emulator locale afterward.

- [ ] **Step 5: Report**

Summarize what was verified (with screenshots) and any deviations. No commit (verification only).

---

## Self-Review (completed by plan author)

- **Spec coverage:** Part 1 scaffold → Task 1; Part 2 Settings → Tasks 8–9 + 10; Part 3 display
  Transpose/order → Task 3; Part 4 playback order/Tempo/Playlist → Task 4, mixer Parts → Tasks 2+5;
  Part 5 Version History → Task 9; Part 6 localization → Task 10; wiring → Tasks 6–7; verification →
  Task 11. All spec sections covered.
- **Placeholders:** Row-body reuse in Task 8 Step 2 references existing composables shown in the
  current file (Repeat/Playlist/Display-mode dropdowns) rather than re-pasting them — these are
  *modifications to existing code already in the repo*, not undefined new code; the new/changed
  composables (scaffold, TempoRow, ContinuationRow, PartMixerSection, A4 row, VersionHistoryScreen,
  grouping) are shown in full.
- **Type consistency:** `groupMixerByPart` / `PartMixerGroup` (Task 2) used consistently in Task 5;
  `InspectorRow` / `InspectorSliderRow` / `InspectorSliderHeight` / `CollapsibleHeader` (Task 1) used
  consistently in Tasks 3–8; `TransposeRow(... showLeadingIcon)` defined in Task 3 and called in
  Tasks 3 & 4; new params added to `DisplayInspectorSheet` (Task 3), `PlaybackInspectorSheet`
  (Task 4), `ReaderScreen` (Task 6) and supplied by callers (Tasks 6–7).
- **Open verification points carried into tasks:** `MixerChannel` field names (Task 2 note),
  `RepeatMode` "off" constant spelling (Task 4 note), `PartDescriptor.name` (Task 6 note), playlist
  origin availability (Task 7 note), Material icon substitutes for iOS SF Symbols (Task 8 note).
