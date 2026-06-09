# Android Reader — Show/Hide Seek Bar Toggle

**Status:** Design approved · 2026-06-09
**Platform:** Android (Compose). No iOS changes.

## Goal

Bring the iOS Reader's show/hide seek-bar behavior to the Android Reader, adapting
the *presentation* to Android idioms while keeping the *content* at iOS parity:

- A user-toggleable "Show seek bar" preference, persisted across scores.
- **Seek bar shown:** a full-width bottom transport bar that fully occupies the
  bottom area (a solid Material surface — *not* the iOS floating glass card).
- **Seek bar hidden:** a floating FAB cluster (play/pause + jump-to-start) over the
  score, mirroring iOS's "floating when collapsed" behavior with Android's FAB idiom.
- The playback inspector entry moves from the bottom bar to the top-right app bar.

### Out of scope

- Next / previous measure (step) buttons — not ported.
- Rehearsal-mark bar — not ported.
- Mirroring the toggle into the app-level Settings screen. The preference lives in the
  Reader's display inspector only (it still persists globally via DataStore). iOS also
  surfaces it in Settings; that mirror is a possible later follow-up.

## Context

Relevant existing code:

- `Android/FolinoReaderAndroid/.../reader/ReaderScreen.kt` — `Scaffold` with `topBar`
  (Back, optional PiP, ViewList=display inspector) and `bottomBar = TransportBar(...)`.
  `TransportBar` currently renders, in one row: play/pause, `mm:ss / mm:ss`, a Material
  `Slider` seek, and a `Tune` IconButton that opens the playback inspector.
- `Android/FolinoReaderAndroid/.../reader/DisplayInspectorSheet.kt` — `ModalBottomSheet`
  with a "General" section of `SwitchRow`s over a `LayoutOptions` value type, plus a
  "Parts" section. Edits flow out via `onChange(LayoutOptions)`; the caller owns
  persistence.
- `Android/FolinoReaderAndroid/.../reader/LayoutOptions.kt` — `LayoutOptions` is the
  immutable display-settings snapshot that **encodes to the JNI layout blob**
  (`LayoutOptionsWireCodec`). It is strictly score-layout state.
- `Android/app/.../ui/settings/SettingsPrefs.kt` — DataStore wrapper. Boolean prefs use
  `booleanPreferencesKey("reader.<name>")` with a `Flow<Boolean>` getter and a
  `suspend fun set<Name>(v)` setter.
- `Android/app/.../MainActivity.kt` — collects each `prefs.*` flow and threads display
  state into `ReaderScreen` via `displayOptions` + `onDisplayOptionsChange`.

iOS reference (`Packages/Features/Reader/`):

- `ReaderTransportControl.swift` — `showSeekBar` switches between an expanded glass card
  (seek bar + transport) and a collapsed floating pill. `ReaderRootScreen` insets the
  horizontal/page viewport by the control's content height; vertical mode uses inset 0.
- `VisualInspectorScreen.swift` — hosts the `Toggle` bound to
  `@AppStorage(ReaderGlobalSettingsKey.showSeekBarEnabled)` (default `true`). The
  preference is a global UserDefaults key, **separate from layout settings**.
- `ReaderTopOverlay.swift` — the playback inspector entry is a top-right icon button.

## Design

### 1. Preference & persistence

The show-seek-bar flag is a Reader UI preference, not score-layout state. Keep it **out
of `LayoutOptions`** (which would otherwise pollute the JNI layout blob), mirroring iOS
where it is a separate `@AppStorage` key rather than a layout setting.

- `SettingsKeys`: add `val showSeekBar = booleanPreferencesKey("reader.showSeekBar.enabled")`.
- `SettingsPrefs`: add
  - `val showSeekBar: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.showSeekBar] ?: true }`
    — default `true` matches iOS.
  - `suspend fun setShowSeekBar(v: Boolean) = context.dataStore.edit { it[SettingsKeys.showSeekBar] = v }`.
- `MainActivity`: collect `prefs.showSeekBar` (`initial = true`) and pass into `ReaderScreen`:
  - `showSeekBar: Boolean`
  - `onShowSeekBarChange: (Boolean) -> Unit = { scope.launch { prefs.setShowSeekBar(it) } }`

### 2. Display-inspector toggle

In `DisplayInspectorSheet`, add a `SwitchRow` to the **General** section:

- Label: new string resource `reader_pref_show_seek_bar` → "Show seek bar".
- `checked = showSeekBar`, `onCheckedChange = onShowSeekBarChange`.

The sheet gains two new parameters (`showSeekBar: Boolean`, `onShowSeekBarChange: (Boolean) -> Unit`)
threaded from `ReaderScreen`. This callback is **separate** from the existing
`onChange(LayoutOptions)` path so the layout blob is untouched. Placement matches iOS,
which keeps the toggle in its display/visual inspector.

### 3. Playback inspector entry → top-right

- Remove the `Tune` `IconButton` from `TransportBar`.
- Add a `Tune` `IconButton` to the `TopAppBar` `actions`, ordered: PiP (if enabled) →
  Tune (playback inspector) → ViewList (display inspector). Its `onClick` sets
  `showInspector = true` (unchanged behavior, new location).

### 4. Bottom area — two states

`ReaderScreen` chooses the Scaffold's bottom presentation from `showSeekBar`:

**Seek bar ON** — `Scaffold(bottomBar = { TransportBar(...) })`:

- `TransportBar` keeps its solid full-width Material bottom-bar surface and fully occupies
  the bottom area. Row contents after this change: play/pause, `mm:ss / mm:ss`, seek
  `Slider` (the `Tune` button is gone — now in the top bar).
- The Scaffold's `bottomBar` automatically insets the content `Box` (via the `padding`
  it already applies) in **all** layout modes, including vertical. This satisfies "when
  the seek bar is on, vertical mode also sits above the playback controls."

**Seek bar OFF** — no `bottomBar`; instead `Scaffold(floatingActionButton = { PlaybackFab(...) }, floatingActionButtonPosition = FabPosition.End)`:

- A `PlaybackFab` cluster floats over the score at the bottom-end. Because a Scaffold FAB
  floats (does not inset content), the score viewport must be inset for the modes where
  fixed-position content would otherwise hide under the FAB:
  - **horizontal / page → inset** the score by the FAB cluster height (iOS parity: these
    modes inset by the control height).
  - **vertical → no inset** (iOS parity: inset 0; the scrolling score passes under the FAB).
- The inset is applied inside the per-mode score composables (the existing
  `ReadyScore` / `HorizontalScore` / `PagedScore` already receive the layout context),
  e.g. as bottom content padding on the score `Box`. A single `bottomScoreInset` value is
  derived in `ReaderScreen` from `(showSeekBar, layoutMode)`:

  | mode       | seek bar ON (bottom bar) | seek bar OFF (FAB)      |
  | ---------- | ------------------------ | ---------------------- |
  | vertical   | inset by Scaffold (auto) | 0 (score under FAB)    |
  | horizontal | inset by Scaffold (auto) | FAB cluster height     |
  | page       | inset by Scaffold (auto) | FAB cluster height     |

  When the seek bar is ON the Scaffold supplies the inset for every mode, so the explicit
  `bottomScoreInset` is only non-zero in the OFF + (horizontal|page) cells.

### 5. PlaybackFab

A small composable cluster, bottom-end, arranged as a horizontal `Row` (spaced):

- `SmallFloatingActionButton` — jump-to-start. Icon `Icons.Default.SkipPrevious`.
  `onClick` → `engine?.seek(0.0)` (Android has no jump-to-start today; this is the
  minimal equivalent of iOS `seekToStart()`).
- `FloatingActionButton` (primary) — play/pause. Icon `Icons.Default.PlayArrow` /
  `Icons.Default.Pause` from `PlaybackState`. `onClick` toggles
  `engine?.play()` / `engine?.pause()`, same logic as the bar's play/pause.

Prepared-state gating mirrors the bar's `isPrepared` semantics (`playback != STOPPED &&
playback != EXPORTING`): guard the `onClick`s so taps before the engine is prepared are
no-ops (and optionally dim the FABs while `!isPrepared`). `FloatingActionButton` has no
`enabled` parameter, so gating is via the click guard rather than a disabled state.

## State & data flow

```
SettingsPrefs.showSeekBar (DataStore, default true)
        │  collect (MainActivity)
        ▼
ReaderScreen(showSeekBar, onShowSeekBarChange, layoutMode, …)
        │
        ├─ showSeekBar == true  → Scaffold.bottomBar = TransportBar   (auto content inset, all modes)
        │
        └─ showSeekBar == false → Scaffold.floatingActionButton = PlaybackFab
                                   + bottomScoreInset = (horizontal|page) ? fabHeight : 0
        │
        └─ DisplayInspectorSheet(showSeekBar, onShowSeekBarChange, …)  // General → "Show seek bar" SwitchRow
```

`onShowSeekBarChange` writes back through `MainActivity` → `prefs.setShowSeekBar` →
DataStore, persisting globally across scores.

## Testing / verification

- Build the app module and the `FolinoReaderAndroid` library.
- Install + launch on Pixel (per project convention for Android changes): toggle the
  "Show seek bar" switch in the display inspector and confirm:
  - ON: full-width bottom bar; score content sits above it in vertical, horizontal, page.
  - OFF: FAB cluster (play/pause + jump-to-start) bottom-end; score sits above it in
    horizontal/page; in vertical the score scrolls under it.
  - The playback inspector opens from the new top-right Tune icon.
  - The preference survives leaving and re-entering the Reader (DataStore persistence).
- No new automated tests required; this is presentation wiring over existing state.

## Risks / notes

- The FAB-vs-bottomBar switch changes the Scaffold's slot usage at runtime; ensure no
  layout jump when toggling (the content inset must update in lockstep with the slot).
- `SmallFloatingActionButton` + primary `FloatingActionButton` in one `floatingActionButton`
  slot: wrap both in a single `Row` so the Scaffold treats them as one FAB anchor.
- Android DataStore key naming follows local convention (`reader.showSeekBar.enabled`);
  it is a separate store from iOS UserDefaults and is not required to share the iOS key
  string.
