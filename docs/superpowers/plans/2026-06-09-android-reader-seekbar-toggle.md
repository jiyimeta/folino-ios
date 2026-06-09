# Android Reader Show/Hide Seek Bar Toggle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Android Reader show/hide its seek bar like iOS — a full-width bottom transport bar when shown, a floating FAB cluster (play/pause + jump-to-start) when hidden — and move the playback-inspector entry to the top-right app bar.

**Architecture:** A new DataStore boolean preference (`reader.showSeekBar.enabled`, default `true`) drives a runtime switch in `ReaderScreen`'s `Scaffold`: `bottomBar = TransportBar` when on, `floatingActionButton = PlaybackFab` when off. The toggle is edited in the Reader's `DisplayInspectorSheet` via a callback that is separate from the `LayoutOptions` JNI-layout path. Score content is inset above the FAB only in horizontal/page modes (vertical scrolls under it), matching iOS.

**Tech Stack:** Kotlin, Jetpack Compose (Material3), AndroidX DataStore. No Swift/JNI changes — the existing `.so` and generated bindings are reused.

**Design spec:** `docs/superpowers/specs/2026-06-09-android-reader-seekbar-toggle-design.md`

**Note on testing:** This is presentation wiring over existing state flows; there is no Compose UI test harness in this module. Per-task verification is **compilation** (`Android/gradlew`), with one final manual install/launch verification on a device. There are no new automated tests, matching the spec.

**Build commands (run from anywhere; gradlew lives in `Android/`):**
- Library module compile: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
- App module compile: `Android/gradlew -p Android :app:compileDebugKotlin`
- Install on device: `Android/gradlew -p Android :app:installDebug`
- Launch: `adb shell am start -n com.keynumber.folino/.MainActivity`

If Gradle tries to rebuild Swift libs and fails (broken swiftly shim), this is a Kotlin-only change — the existing libs in the primary checkout are reused; do not regenerate them. See memory `project_android_build_toolchain` only if a Swift task is unexpectedly triggered.

---

## File Structure

- **Modify** `Android/app/.../ui/settings/SettingsPrefs.kt` — add the `showSeekBar` key, flow, and setter.
- **Modify** `Android/FolinoReaderAndroid/src/main/res/values{,-ja,-zh-rTW,-zh-rCN,-ko}/strings.xml` — add `reader_pref_show_seek_bar`.
- **Modify** `Android/FolinoReaderAndroid/.../reader/DisplayInspectorSheet.kt` — two new params + a "Show seek bar" `SwitchRow` in the General section.
- **Modify** `Android/FolinoReaderAndroid/.../reader/ReaderScreen.kt` — new params; move the playback-inspector `Tune` button to the top bar; switch `bottomBar` ↔ `floatingActionButton`; add the `PlaybackFab` composable; inset score content for horizontal/page when the FAB is showing; trim `TransportBar`.
- **Modify** `Android/app/.../MainActivity.kt` — collect the new pref and thread `showSeekBar` / `onShowSeekBarChange` into `ReaderScreen`.

---

## Task 1: Add the `showSeekBar` DataStore preference

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt`

- [ ] **Step 1: Add the preference key**

In `object SettingsKeys`, after the `pageTapHintDismissed` key (line ~36), add:

```kotlin
    /** Whether the Reader shows the full-width seek bar (true) or the floating play FAB (false).
     * Default true mirrors iOS `ReaderGlobalSettingsKey.showSeekBarEnabled`. UI-only; not part of
     * the JNI layout blob. */
    val showSeekBar = booleanPreferencesKey("reader.showSeekBar.enabled")
```

- [ ] **Step 2: Add the flow getter**

In `class SettingsPrefs`, after the `pageTapHintDismissed` flow (line ~61), add:

```kotlin
    val showSeekBar: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.showSeekBar] ?: true }
```

- [ ] **Step 3: Add the setter**

After `setPageTapHintDismissed()` (line ~76), add:

```kotlin
    suspend fun setShowSeekBar(v: Boolean) = context.dataStore.edit { it[SettingsKeys.showSeekBar] = v }
```

- [ ] **Step 4: Compile the app module**

Run: `Android/gradlew -p Android :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt
git commit -m "feat(android-reader): add showSeekBar DataStore preference"
```

---

## Task 2: Add the "Show seek bar" string resource

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/res/values/strings.xml`
- Modify: `Android/FolinoReaderAndroid/src/main/res/values-ja/strings.xml`
- Modify: `Android/FolinoReaderAndroid/src/main/res/values-zh-rTW/strings.xml`
- Modify: `Android/FolinoReaderAndroid/src/main/res/values-zh-rCN/strings.xml`
- Modify: `Android/FolinoReaderAndroid/src/main/res/values-ko/strings.xml`

Only this one user-visible string is added. The playback-inspector top-bar button reuses the existing literal content description `"Playback controls"` (already present in `ReaderScreen.kt`), so no new string is needed for it.

- [ ] **Step 1: Add the English (default) string**

In `values/strings.xml`, beside the other `reader_pref_*` entries (after `reader_pref_show_invisible`), add:

```xml
    <string name="reader_pref_show_seek_bar">Show seek bar</string>
```

- [ ] **Step 2: Add the Japanese string**

In `values-ja/strings.xml`, in the same relative position:

```xml
    <string name="reader_pref_show_seek_bar">シークバーを表示</string>
```

- [ ] **Step 3: Add the Simplified Chinese string**

In `values-zh-rCN/strings.xml`:

```xml
    <string name="reader_pref_show_seek_bar">显示进度条</string>
```

- [ ] **Step 4: Add the Traditional Chinese string**

In `values-zh-rTW/strings.xml`:

```xml
    <string name="reader_pref_show_seek_bar">顯示進度列</string>
```

- [ ] **Step 5: Add the Korean string**

In `values-ko/strings.xml`:

```xml
    <string name="reader_pref_show_seek_bar">탐색 막대 표시</string>
```

- [ ] **Step 6: Compile the library module**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL (resource merge succeeds; `R.string.reader_pref_show_seek_bar` is generated).

- [ ] **Step 7: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/res
git commit -m "feat(android-reader): add show-seek-bar toggle string (en/ja/zh/ko)"
```

---

## Task 3: Add the toggle row to the display inspector

**Files:**
- Modify: `Android/FolinoReaderAndroid/.../reader/DisplayInspectorSheet.kt`

- [ ] **Step 1: Add two parameters to `DisplayInspectorSheet`**

Change the signature (currently lines ~104-111) to add `showSeekBar` and `onShowSeekBarChange`, with defaults so the file still compiles before its caller is updated:

```kotlin
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DisplayInspectorSheet(
    options: LayoutOptions,
    parts: List<PartDescriptor>,
    sheetState: SheetState,
    onDismiss: () -> Unit,
    onChange: (LayoutOptions) -> Unit,
    showSeekBar: Boolean = true,
    onShowSeekBarChange: (Boolean) -> Unit = {},
) {
```

- [ ] **Step 2: Add the "Show seek bar" SwitchRow to the General section**

Inside `if (generalExpanded) { ... }`, after the `reader_pref_show_invisible` `SwitchRow` item (line ~152), add a new item. It calls `onShowSeekBarChange` directly — it does NOT go through `onChange(options.copy(...))`, because the flag is not part of `LayoutOptions`:

```kotlin
                item {
                    SwitchRow(
                        label = stringResource(R.string.reader_pref_show_seek_bar),
                        checked = showSeekBar,
                    ) { onShowSeekBarChange(it) }
                }
```

- [ ] **Step 3: Compile the library module**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/DisplayInspectorSheet.kt
git commit -m "feat(android-reader): show-seek-bar toggle in display inspector"
```

---

## Task 4: Rework `ReaderScreen` bottom area + top-bar inspector entry

**Files:**
- Modify: `Android/FolinoReaderAndroid/.../reader/ReaderScreen.kt`

This is the core task. Sub-steps: add imports, add params, add top-bar Tune button, switch Scaffold slots, inset content, trim `TransportBar`, add `PlaybackFab`.

- [ ] **Step 1: Add the new imports**

Near the other `androidx.compose.*` imports (top of file, lines ~9-56), add:

```kotlin
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.FabPosition
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.SmallFloatingActionButton
```

(`Arrangement`, `Row`, `Icons`, `Icon`, `Modifier`, `dp`, `padding`, `Alignment`, `Pause`, `PlayArrow`, `Tune` are already imported.)

- [ ] **Step 2: Add two parameters to `ReaderScreen`**

In the parameter list (lines ~74-90), after `pipEnabled` and before `readerVm`, add (defaults keep the file compiling before `MainActivity` is updated):

```kotlin
    /** When true, show the full-width seek bar (bottom bar); when false, the floating play FAB. */
    showSeekBar: Boolean = true,
    onShowSeekBarChange: (Boolean) -> Unit = {},
```

- [ ] **Step 3: Add a content-inset constant**

Just above the `ReaderScreen` function (line ~72, before `@OptIn`), add a top-level private constant for the height the floating FAB cluster reserves (FAB 56 + bottom margin 16 + top breathing 16):

```kotlin
/** Bottom inset reserved for the floating playback FAB cluster, so fixed-position score content
 * (horizontal / page modes) is not hidden under it. Vertical mode does not use this — its scrolling
 * content passes under the FAB, matching iOS (vertical inset 0). */
private val fabClusterReservedHeight = 88.dp
```

- [ ] **Step 4: Add the playback-inspector button to the top bar**

In the `TopAppBar` `actions = { ... }` block (lines ~172-188), after the PiP `IconButton` and before the display-inspector `ViewList` `IconButton`, add the playback-inspector entry (moved here from `TransportBar`):

```kotlin
                    IconButton(onClick = { showInspector = true }) {
                        Icon(Icons.Default.Tune, contentDescription = "Playback controls")
                    }
```

Resulting action order: PiP (if enabled) → Tune (playback) → ViewList (display).

- [ ] **Step 5: Switch the Scaffold's bottom slots**

Replace the current `bottomBar = { TransportBar(audioVm, onOpenInspector = { showInspector = true }) },` line (line ~191) with a conditional bottom bar plus a conditional FAB:

```kotlin
        bottomBar = { if (showSeekBar) TransportBar(audioVm) },
        floatingActionButton = { if (!showSeekBar) PlaybackFab(audioVm) },
        floatingActionButtonPosition = FabPosition.End,
```

When `showSeekBar` is true the FAB lambda renders nothing (no FAB); when false the `bottomBar` lambda renders nothing (Scaffold reserves no bottom inset). `showInspector` is still the same state the top-bar button now sets.

- [ ] **Step 6: Inset the content Box for horizontal/page when the FAB shows**

The Scaffold content is `Box(Modifier.padding(padding).fillMaxSize(), ...)` (lines ~193-198). When the seek bar is on, the `bottomBar` already insets `padding` for every mode (this satisfies "vertical also sits above the controls"). When the seek bar is off, the FAB floats, so add explicit bottom padding for the fixed-layout modes only. Change the `Box` modifier to:

```kotlin
        Box(
            Modifier
                .padding(padding)
                .padding(
                    bottom = if (!showSeekBar &&
                        (layoutMode == ReaderLayoutMode.HORIZONTAL || layoutMode == ReaderLayoutMode.PAGE)
                    ) {
                        fabClusterReservedHeight
                    } else {
                        0.dp
                    },
                )
                .fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
```

(Vertical mode gets `0.dp`, so its scrolling score passes under the FAB — iOS parity.)

- [ ] **Step 7: Trim `TransportBar` (drop the inspector button and its param)**

Replace the whole `TransportBar` composable (lines ~430-474) with the version below — it loses the `onOpenInspector` parameter and the trailing `Tune` `IconButton`; everything else (play/pause, time, slider, full-width solid bottom bar) is unchanged:

```kotlin
@Composable
private fun TransportBar(audioVm: ReaderAudioViewModel) {
    val playback by audioVm.state.collectAsStateWithLifecycle()
    val currentSecs by audioVm.currentTimeSeconds.collectAsStateWithLifecycle()
    val totalSecs by audioVm.totalTimeSeconds.collectAsStateWithLifecycle()
    val engine by audioVm.engine.collectAsStateWithLifecycle()

    val isPrepared = playback != PlaybackState.STOPPED && playback != PlaybackState.EXPORTING

    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconButton(
                onClick = {
                    if (playback == PlaybackState.PLAYING) engine?.pause() else engine?.play()
                },
                enabled = isPrepared,
            ) {
                if (playback == PlaybackState.PLAYING) {
                    Icon(Icons.Default.Pause, contentDescription = "Pause")
                } else {
                    Icon(Icons.Default.PlayArrow, contentDescription = "Play")
                }
            }
            Text(
                text = "${formatTime(currentSecs)} / ${formatTime(totalSecs)}",
                style = MaterialTheme.typography.bodySmall,
            )
            Slider(
                value = if (totalSecs > 0) (currentSecs / totalSecs).toFloat().coerceIn(0f, 1f) else 0f,
                onValueChange = { fraction ->
                    if (totalSecs > 0) engine?.seek(fraction * totalSecs)
                },
                enabled = isPrepared,
                modifier = Modifier.weight(1f),
            )
        }
    }
}
```

- [ ] **Step 8: Add the `PlaybackFab` composable**

Immediately after `TransportBar` (before `private fun formatTime(...)`), add the floating FAB cluster. The primary FAB is play/pause; the small FAB is jump-to-start. Both guard their actions on `isPrepared` (mirroring the bar's gating), since `FloatingActionButton` has no `enabled` parameter:

```kotlin
/**
 * Floating transport cluster shown when the seek bar is hidden (iOS "collapsed/floating" parity,
 * adapted to Android's FAB idiom). A small jump-to-start FAB sits left of the primary play/pause
 * FAB at the bottom-end. Step (prev/next measure) and the rehearsal-mark bar are intentionally
 * not ported. Actions are guarded on the prepared state, matching [TransportBar].
 */
@Composable
private fun PlaybackFab(audioVm: ReaderAudioViewModel) {
    val playback by audioVm.state.collectAsStateWithLifecycle()
    val engine by audioVm.engine.collectAsStateWithLifecycle()
    val isPrepared = playback != PlaybackState.STOPPED && playback != PlaybackState.EXPORTING

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SmallFloatingActionButton(
            onClick = { if (isPrepared) engine?.seek(0.0) },
        ) {
            Icon(Icons.Default.SkipPrevious, contentDescription = "Jump to start")
        }
        FloatingActionButton(
            onClick = {
                if (isPrepared) {
                    if (playback == PlaybackState.PLAYING) engine?.pause() else engine?.play()
                }
            },
        ) {
            if (playback == PlaybackState.PLAYING) {
                Icon(Icons.Default.Pause, contentDescription = "Pause")
            } else {
                Icon(Icons.Default.PlayArrow, contentDescription = "Play")
            }
        }
    }
}
```

- [ ] **Step 9: Pass the new toggle state into `DisplayInspectorSheet`**

In the `if (showDisplayInspector) { DisplayInspectorSheet(...) }` block (lines ~227-235), add the two new arguments:

```kotlin
        DisplayInspectorSheet(
            options = displayOptions,
            parts = parts,
            sheetState = displaySheetState,
            onDismiss = { showDisplayInspector = false },
            onChange = onDisplayOptionsChange,
            showSeekBar = showSeekBar,
            onShowSeekBarChange = onShowSeekBarChange,
        )
```

- [ ] **Step 10: Compile the library module**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL. (If `PaddingValues` import is reported unused, remove it — it is only listed in case the inset is refactored; the `padding(bottom = …)` form above does not require it. Prefer removing the unused import to satisfy the lint/detekt gate.)

- [ ] **Step 11: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(android-reader): floating play FAB when seek bar hidden; inspector to top bar"
```

---

## Task 5: Thread the preference through `MainActivity`

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Collect the new preference flow**

In the Reader `composable` block, beside the other `prefs.*` collectors (after `val pipEnabled by prefs.pip.collectAsState(initial = false)`, line ~407), add:

```kotlin
                val showSeekBar by prefs.showSeekBar.collectAsState(initial = true)
```

- [ ] **Step 2: Pass the new arguments to `ReaderScreen`**

In the `ReaderScreen(...)` call (lines ~412-433), after `pipEnabled = pipEnabled,` and before `onBack = ...`, add:

```kotlin
                    showSeekBar = showSeekBar,
                    onShowSeekBarChange = { v -> scope.launch { prefs.setShowSeekBar(v) } },
```

(`scope` is already defined in this block as `rememberCoroutineScope()`.)

- [ ] **Step 3: Compile the app module**

Run: `Android/gradlew -p Android :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android-reader): wire showSeekBar pref into ReaderScreen"
```

---

## Task 6: Build, install, and manually verify on device

**Files:** none (verification only).

- [ ] **Step 1: Install the debug build on a connected device**

Run: `Android/gradlew -p Android :app:installDebug`
Expected: BUILD SUCCESSFUL, `Installed on 1 device`.

- [ ] **Step 2: Launch the app**

Run: `adb shell am start -n com.keynumber.folino/.MainActivity`
Expected: app launches.

- [ ] **Step 3: Verify manually (open a score in the Reader)**

Confirm each, in each layout mode (vertical / horizontal / page) via the display inspector's layout selector:

- The top-right app bar shows the playback-inspector (Tune) button; tapping it opens the playback inspector sheet.
- Display inspector → General has a "Show seek bar" switch.
- **Switch ON:** full-width bottom bar (play/pause + `mm:ss / mm:ss` + slider); score content sits above the bar in all three modes (nothing hidden under it).
- **Switch OFF:** a floating FAB cluster (small jump-to-start + primary play/pause) at the bottom-end; in horizontal/page the score sits above the FAB; in vertical the score scrolls under the FAB.
- Play/pause and jump-to-start work from both the bar and the FAB.
- Toggle persists: flip it, leave the Reader, re-enter — the chosen state is restored (DataStore).

- [ ] **Step 4: Report results**

Per project convention, report build + launch outcome and the manual-verification observations. Do not push; leave commits local for review.

---

## Self-Review notes

- **Spec coverage:** preference + persistence (Task 1, 5) · display-inspector toggle (Task 2, 3) · inspector → top-right (Task 4 step 4) · seek-bar-on full bottom bar with all-mode inset (Task 4 steps 5-6) · seek-bar-off floating FAB with play/pause + jump-to-start and horizontal/page-only inset (Task 4 steps 5-8) · out-of-scope items (step buttons, rehearsal bar, Settings mirror) are not added. All covered.
- **Type/name consistency:** `showSeekBar` / `onShowSeekBarChange` are spelled identically across `SettingsPrefs`, `DisplayInspectorSheet`, `ReaderScreen`, and `MainActivity`. `TransportBar` loses `onOpenInspector` in Task 4 step 7 and is called with the new arity in step 5. `PlaybackFab` is defined (step 8) before its only call site (step 5, same file).
- **No placeholders:** every code step shows the full edit.
