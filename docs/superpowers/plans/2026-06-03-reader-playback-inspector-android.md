# Reader Playback Inspector (Android) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Android playback controls panel (per-staff mixer, master volume, tempo, metronome) to the Reader, opened from a transport-bar icon as a `ModalBottomSheet`.

**Architecture:** A thin reactive Compose binding over the existing `AndroidPlaybackEngine` (which already owns all playback/mix semantics, shared with iOS). The sheet reads engine `StateFlow`s and writes via engine setters on interaction. Two controls the engine does not expose as observable state (master volume, metronome on/off) get small UI-facing pass-throughs on `ReaderAudioViewModel`. No sheet-music changes, no JNI changes.

**Tech Stack:** Kotlin, Jetpack Compose (Material3), Kotlin coroutines `StateFlow`. Module: `Android/FolinoReaderAndroid/` (Kotlin-only Android library).

---

## Background & key decisions (read before starting)

This plan implements **section C** of the approved design doc
`docs/superpowers/specs/2026-06-03-reader-playback-inspector-design.md`. Read that doc's
**section B (environment gotchas)** before building — the Android build is finicky
(toolchain PATH split, `--no-daemon`, wirelet StringCodec trap). This plan is built on
branch `reader-playback-inspector` in the **primary worktree**
(`/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS`), which is already
native-bootstrapped — do not create a fresh worktree (avoids ~10 min of native rebuilds).

**Three deviations from the design doc's section C, all toward better parity / less code:**

1. **No `GmInstruments.kt`.** The doc proposed a hand-written 128-name Kotlin GM list.
   The sheet-music Android audio lib **already ships** `GMInstrument` with a cached
   `entries: List<GMInstrument>` (program, displayName, familyIndex) loaded via JNI from
   the **shared Swift** `SheetMusicAudioCore.GMInstrument` — Swift is the source of truth,
   so this is strictly better for iOS/Android parity. Use it; do not hand-copy names.
   - Source: `io.github.jiyimeta.sheetmusic.audio.model.GMInstrument`
     (`entries`, `forProgram(program: Int): GMInstrument?`).

2. **Master volume & metronome get VM pass-throughs.** The engine exposes `setMasterVolume`
   / `setMetronomeEnabled` but **no** observable `StateFlow` for either. For the sheet's
   UI to reflect its own state across open/close within a Reader session, add
   `masterVolume`/`metronomeEnabled` `StateFlow`s + setter methods to `ReaderAudioViewModel`
   (the doc explicitly allows "small pass-throughs if cleaner"). Per-staff volume/mute/solo/
   program and tempo are read straight from the engine's existing `mixerChannels` /
   `currentRate` flows and written via engine setters — no VM state needed for those.

3. **No TDD unit-test steps.** This slice is pure reactive UI binding: master volume is a
   linear 0–1 slider, tempo a linear 0.5×–2.0× multiplier slider — no pure logic worth a
   unit test, and the module has no test harness (no `test`/`androidTest` source sets, no
   test deps). The design doc's verification is explicitly **device + ear** (the user
   listens). So each task verifies by Kotlin compile, and the final task verifies on the
   Pixel 8a. (If a future slice adds a non-trivial taper/BPM mapping like iOS's, that pure
   function should be unit-tested.)

**Parity note (governs this whole slice):** audio *semantics* are already shared Swift (the
engine); Android only drives it. The UI *mappings* (slider feel, % readout) are UI/UX and
are implemented Android-idiomatically — NOT shared via JNI. See `feedback_ios_android_parity`.

**Engine API this plan calls** (all on `AndroidPlaybackEngine`, verified present):
- `fun setStaffVolume(staffIndex: Int, volume: Float)` — 0..1
- `fun setStaffMuted(staffIndex: Int, muted: Boolean)`
- `fun setStaffSoloed(staffIndex: Int, soloed: Boolean)`
- `fun setStaffProgram(staffIndex: Int, program: Int)` — GM 0..127
- `fun setMasterVolume(volume: Float)` — 0..1
- `fun setRate(rate: Float)`
- `fun setMetronomeEnabled(enabled: Boolean)`
- `val mixerChannels: StateFlow<List<MixerChannel>>`, `val currentRate: StateFlow<Float>`
- `MixerChannel = { staffIndex: Int, displayName: String, volume: Float, isMuted: Boolean, isSoloed: Boolean, effectiveMute: Boolean, program: Int? }` (`program == null` ⇒ drums)

---

## File Structure

- **Modify** `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt`
  — add `masterVolume`/`metronomeEnabled` `StateFlow`s + `setMasterVolume`/`setMetronomeEnabled`
  pass-throughs (the only two controls without an engine-side observable).
- **Create** `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt`
  — the `ModalBottomSheet` composable with Master / Tempo / Metronome / Mixer sections,
  binding to `ReaderAudioViewModel` + the engine setters.
- **Modify** `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`
  — add a `Tune` `IconButton` to `TransportBar`, host `rememberModalBottomSheetState`, and
  show/hide `PlaybackInspectorSheet`.

No new files beyond `PlaybackInspectorSheet.kt`; the GM catalog comes from the audio lib.

---

## Task 1: Add master-volume + metronome pass-throughs to `ReaderAudioViewModel`

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt`

These two controls have no observable engine `StateFlow`, so the VM holds UI-facing state
(defaults match the engine's post-prepare defaults: master 1.0, metronome off) and forwards
writes to the engine. Per-staff volume/mute/solo/program and tempo are NOT added here — they
already have engine observables (`mixerChannels`, `currentRate`).

- [ ] **Step 1: Add the two StateFlows after `loopRange`**

In `ReaderAudioViewModel.kt`, immediately after the `loopRange` declaration (currently
ending around line 82), add:

```kotlin
    // ── UI-facing controls without an engine-side observable ─────────
    // The engine exposes setMasterVolume / setMetronomeEnabled but no StateFlow for
    // either, so the inspector's UI state lives here (session-only, matching the Reader
    // MVP — no persistence). Defaults mirror the engine's post-prepare defaults.
    private val _masterVolume = MutableStateFlow(1.0f)
    val masterVolume: StateFlow<Float> = _masterVolume.asStateFlow()

    private val _metronomeEnabled = MutableStateFlow(false)
    val metronomeEnabled: StateFlow<Boolean> = _metronomeEnabled.asStateFlow()

    /** Sets master output volume (0..1) and reflects it for the inspector UI. */
    fun setMasterVolume(volume: Float) {
        _masterVolume.value = volume
        engine.value?.setMasterVolume(volume)
    }

    /** Enables/disables the metronome and reflects it for the inspector UI. */
    fun setMetronomeEnabled(enabled: Boolean) {
        _metronomeEnabled.value = enabled
        engine.value?.setMetronomeEnabled(enabled)
    }
```

`MutableStateFlow`, `StateFlow`, `asStateFlow` are already imported in this file.

- [ ] **Step 2: Verify Kotlin compiles**

Run (with the Xcode default toolchain on PATH; `--no-daemon`):

```bash
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
  Android/gradlew --no-daemon -p Android :FolinoReaderAndroid:compileDebugKotlin
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt
git commit -m "feat(reader-android): add master-volume + metronome UI pass-throughs"
```

---

## Task 2: Create `PlaybackInspectorSheet.kt`

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt`

A `ModalBottomSheet` with four sections: Master volume, Tempo, Metronome, and the per-staff
Mixer. Reads engine flows (`mixerChannels`, `currentRate`) + VM flows (`masterVolume`,
`metronomeEnabled`); writes via engine setters / VM setters. Controls are disabled when the
engine isn't bound yet. Drums rows (`program == null`) hide the program picker.

The mixer uses a `Column` + `verticalScroll` (not a nested `LazyColumn`) — staff counts are
tiny and this avoids nested-scroll friction inside the sheet. The GM program list comes from
the audio lib's shared `GMInstrument.entries` (loaded once via `remember`).

- [ ] **Step 1: Write the file**

```kotlin
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
 * A thin reactive binding over [ReaderAudioViewModel] / [AndroidPlaybackEngine]: the engine
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
    Text(
        text = title,
        style = androidx.compose.material3.MaterialTheme.typography.titleSmall,
    )
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
            if (channel.program != null) {
                ProgramPickerButton(
                    program = channel.program,
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
```

- [ ] **Step 2: Verify Kotlin compiles**

```bash
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
  Android/gradlew --no-daemon -p Android :FolinoReaderAndroid:compileDebugKotlin
```

Expected: `BUILD SUCCESSFUL`. If an icon or Material3 symbol is unresolved, confirm it
against the BOM (`compose-bom:2024.09.02`) and `material-icons-extended` (both already in
`build.gradle.kts`) — `Icons.Default.ArrowDropDown`, `FilterChip`, `Switch`, `ModalBottomSheet`,
`DropdownMenu` are all present there.

- [ ] **Step 3: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt
git commit -m "feat(reader-android): add playback inspector bottom sheet"
```

---

## Task 3: Wire the inspector into `ReaderScreen`

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`

Add a `Tune` icon to the transport bar that opens the sheet. The sheet's open/close state and
`SheetState` are hoisted into `ReaderScreen` (the composable that owns the `Scaffold`), and the
sheet is rendered at that level so it overlays the whole screen.

- [ ] **Step 1: Add imports**

In `ReaderScreen.kt`, add these imports alongside the existing ones (keep alphabetical-ish
grouping with the current imports):

```kotlin
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
```

(`Icons`, `Icon`, `IconButton`, `ExperimentalMaterial3Api`, `Composable`, `getValue`,
`mutableStateOf`, `remember`, `setValue` are already imported.)

- [ ] **Step 2: Host the sheet state in `ReaderScreen` and render the sheet**

In `ReaderScreen`, add the sheet state just after the existing `fontProvider`/`state` setup
(after the two `LaunchedEffect` lines, before `Scaffold`):

```kotlin
    var showInspector by remember { mutableStateOf(false) }
    val inspectorSheetState = rememberModalBottomSheetState()
```

Then change the `bottomBar` to pass an open callback into `TransportBar`:

```kotlin
        bottomBar = { TransportBar(audioVm, onOpenInspector = { showInspector = true }) },
```

Finally, render the sheet. Place this immediately after the `Scaffold { … }` closing brace,
inside `ReaderScreen`'s body (so it overlays the scaffold):

```kotlin
    if (showInspector) {
        PlaybackInspectorSheet(
            audioVm = audioVm,
            sheetState = inspectorSheetState,
            onDismiss = { showInspector = false },
        )
    }
```

- [ ] **Step 3: Add the Tune icon to `TransportBar`**

Change `TransportBar`'s signature and add the icon button. Replace the current
`private fun TransportBar(audioVm: ReaderAudioViewModel)` signature with:

```kotlin
@Composable
private fun TransportBar(audioVm: ReaderAudioViewModel, onOpenInspector: () -> Unit) {
```

Then, inside the inner `Row` (the one holding the play/pause button, time text, and seek
slider), add the inspector button as the last child — after the seek `Slider`. Because the
seek `Slider` currently uses `Modifier.fillMaxWidth()` it consumes all remaining width; change
that slider's modifier to `Modifier.weight(1f)` so the new icon has room, then add the button:

Change:

```kotlin
            Slider(
                value = if (totalSecs > 0) (currentSecs / totalSecs).toFloat().coerceIn(0f, 1f) else 0f,
                onValueChange = { fraction ->
                    if (totalSecs > 0) engine?.seek(fraction * totalSecs)
                },
                enabled = isPrepared,
                modifier = Modifier.fillMaxWidth(),
            )
```

to:

```kotlin
            Slider(
                value = if (totalSecs > 0) (currentSecs / totalSecs).toFloat().coerceIn(0f, 1f) else 0f,
                onValueChange = { fraction ->
                    if (totalSecs > 0) engine?.seek(fraction * totalSecs)
                },
                enabled = isPrepared,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onOpenInspector, enabled = isPrepared) {
                Icon(Icons.Default.Tune, contentDescription = "Playback controls")
            }
```

- [ ] **Step 4: Verify Kotlin compiles**

```bash
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
  Android/gradlew --no-daemon -p Android :FolinoReaderAndroid:compileDebugKotlin
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(reader-android): open playback inspector from transport bar"
```

---

## Task 4: Full app build + device verification

**Files:** none (build + manual verification + memory update).

- [ ] **Step 1: Assemble + install the app on the Pixel 8a**

```bash
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
  Android/gradlew --no-daemon -p Android :app:installDebug
```

Expected: `BUILD SUCCESSFUL` and `Installed on 1 device`. If a wirelet `StringCodec` compile
error appears, apply design-doc gotcha **B.4** (chmod + delete the stale
`Packages/Features/Library/.build/checkouts/swift-wirelet` CLI build, regenerate).

- [ ] **Step 2: Launch**

```bash
adb shell am start -n com.keynumber.folino/.MainActivity
```

(Dismiss the 16 KB-compat dialog if it appears — "次回から表示しない".)

- [ ] **Step 3: Manual verification (the user listens — do not judge audio programmatically)**

Hand control to the user with this checklist:
1. Open a Library score → it opens the Reader.
2. Press play → the transport `Tune` icon is enabled; tap it → the bottom sheet opens.
3. **Master**: drag Volume → overall loudness changes; readout tracks %.
4. **Tempo**: drag Rate → playback speeds up/slows; readout shows ×0.50–×2.00.
5. **Metronome**: toggle Click on → metronome clicks are audible; off → silent.
6. **Mixer**: for a multi-staff score — drag a staff Volume (that staff's level changes);
   tap **M** (that staff goes silent, chip fills); tap **S** on another staff (other staves
   become effectively muted, their sliders disable); change a non-drum staff's instrument via
   the dropdown (its timbre changes). A drums staff shows "Drums", no picker.

- [ ] **Step 4: Capture a screenshot for the record (optional, visual sanity)**

```bash
adb exec-out screencap -p > /tmp/reader-inspector.png
```

`Read` the PNG to confirm the sheet renders (sections + mixer rows). Audio correctness is the
user's call.

- [ ] **Step 5: Update memory**

Update `project_reader_android_mvp` (or add a `project_reader_playback_inspector` note) to
record: inspector done on branch `reader-playback-inspector`, per-staff mixer + master + tempo
+ metronome, verified on Pixel 8a; deferred = visual inspector + A-B loop + per-part program
fan-out + persistence.

- [ ] **Step 6: Ask the user how to integrate** (merge to `main`, per design-doc section D.4).
  Do not merge/push without explicit instruction (autonomous ground rules + `feedback_no_auto_commit`).

---

## Self-Review

**Spec coverage (design-doc section C):**
- Per-staff mixer volume/mute/solo/program → Task 2 `MixerRow` + Task 4 verify. ✓
- Master volume → Task 1 pass-through + Task 2 Master section. ✓
- Tempo 0.5×–2.0× → Task 2 Tempo section (`engine.setRate`). ✓
- Metronome on/off → Task 1 pass-through + Task 2 Metronome section. ✓
- `ModalBottomSheet` opened from a transport-bar `Tune` icon → Task 3. ✓
- Drums (`program == null`) show "Drums", no picker → Task 2 `MixerRow`. ✓
- Engine-null ⇒ controls disabled; empty `mixerChannels` ⇒ empty mixer → Task 2. ✓
- No sheet-music / JNI changes; session-only, no persistence → honored (VM state, no store). ✓
- Deviations (no `GmInstruments.kt`; VM pass-throughs; no TDD) documented above with rationale. ✓
- OUT of scope (visual inspector, A-B loop, per-part fan-out, persistence) → not implemented. ✓

**Type consistency:** `audioVm.engine/mixerChannels/currentRate` (existing) + `masterVolume/
metronomeEnabled/setMasterVolume/setMetronomeEnabled` (Task 1) are used consistently in Task 2.
`MixerChannel` fields (`staffIndex`, `displayName`, `volume`, `isMuted`, `isSoloed`,
`effectiveMute`, `program`) match the lib's data class. `GMInstrument.entries` /
`.displayName` / `.program` match the lib. Engine setter signatures match the verified API.
`TransportBar(audioVm, onOpenInspector)` call site (Task 3 Step 2) matches its new signature
(Task 3 Step 3).

**Placeholder scan:** no TBD/TODO/"add error handling"/"similar to" — all steps carry full code.
