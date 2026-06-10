# Android Settings Persistence — iOS Scope Parity

**Date:** 2026-06-10
**Status:** Design (awaiting review)
**Platforms:** Android (iOS is the reference; minimal shared-code additions touch Domain + the `LibraryStore` wirelet interface)

## Problem

Several Reader/Settings controls on Android do not persist, and a few that *do*
persist use the wrong scope relative to iOS. Concretely:

- **Not persisted at all (session-only)** — master volume, tempo, per-score A4
  override, and the per-staff mixer overrides (program / volume) live only in
  `ReaderAudioViewModel` / the engine and are lost when the score closes.
- **Wrong scope** — staff size, hidden staves, clef overrides, and honor-layout-breaks
  are persisted **globally** in DataStore on Android, but iOS stores them **per-score**.
- **Missing settings keys for not-yet-built features** — iOS has a global
  `playlistContinuationMode` and a per-score `transposeSemitones`. Android has
  neither the persisted value nor the settings UI, even though the features that
  *consume* them (playlist continuation, transpose) are slated for later.

The user wants Android to reach **full iOS parity on settings persistence and
scope**, *including* settings whose consuming feature is not yet implemented on
Android — persist the value (and surface the settings UI) now, wire the behavior
later. Android is **unreleased**, so no data migration of existing values is
required; scope changes can reset freely.

## Goals

1. Every per-score setting iOS stores in `ReaderPreferences` is persisted
   per-score on Android, at byte-compatible JSON, via the **shared Domain
   `ReaderPreferences`** type (single source of truth, shared clamping/normalization).
2. Every global setting iOS stores in `@AppStorage` is persisted globally on
   Android in DataStore (already true except `playlistContinuationMode`, added here).
3. The display settings currently mis-scoped to global on Android move to per-score.
4. New parity settings UI is added for the two not-yet-implemented features:
   - `playlistContinuationMode` — 3-way picker in the Settings screen.
   - `transposeSemitones` — stepper row in the playback inspector.
   Both **persist** their value; their runtime *effect* is out of scope (later work).
5. The playback-inspector metronome toggle binds to the existing **global**
   metronome DataStore key (iOS treats metronome as global), instead of its current
   session-only flag.

## Non-Goals

- Implementing the playlist-continuation playback behavior on Android.
- Implementing the transpose audio/notation effect on Android (engine RPN coarse
  tuning + `Score.transposed` re-layout). Only the persisted value + UI control.
- Any iOS behavior change. iOS is the reference; the only iOS-touching changes are
  additive and shared (Domain `ReaderPreferences` already has every field; the
  `LibraryStore` wirelet interface gains two String-typed methods).
- Persisting genuinely transient state that iOS also leaves transient: mixer
  mute/solo, A/B pending markers, inspector section expand/collapse.

## Settings Inventory & Target State

### Global (DataStore on Android — already correct unless noted)

| Setting | iOS key | Android now | Action |
| --- | --- | --- | --- |
| Layout mode | `layoutMode` | DataStore ✓ | none |
| Show invisible elements | `showInvisibleElements` | DataStore ✓ | none |
| Collapse multi-measure rests | `collapseMultiMeasureRests` | DataStore ✓ | none |
| Show seek bar | `showSeekBarEnabled` | DataStore ✓ | none |
| Metronome | `metronomeEnabled` | DataStore ✓ (Settings) / **session-only (inspector)** | **bind inspector toggle to the global key** |
| Repeat mode | `repeatMode` | DataStore ✓ | none |
| A4 reference (global default) | `a4ReferenceHz` | DataStore ✓ | none |
| Picture-in-Picture | `pictureInPictureEnabled` | DataStore ✓ | none |
| Keep screen awake | `keepScreenAwakeEnabled` | DataStore ✓ | none |
| Crash reporting | `crashReportingEnabled` | DataStore ✓ | none |
| Page-tap hint dismissed | `pageTapHintDismissed` | DataStore ✓ | none |
| **Playlist continuation mode** | `playlistContinuationMode` | **absent** | **add DataStore key + getter/setter + Settings UI** |

### Per-score (iOS: SQLite `ReaderPreferences`; Android target: Room `reader_preferences` JSON blob)

| Setting | `ReaderPreferences` field | Android now | Action |
| --- | --- | --- | --- |
| Staff size | `staffSize` | global DataStore | **move to per-score blob** |
| Hidden staves | `hiddenStaves` | global DataStore | **move to per-score blob** |
| Honor layout breaks | `honorLayoutBreaks` | global DataStore | **move to per-score blob** |
| Clef overrides | `staffClefOverrides` | global DataStore | **move to per-score blob** |
| Master volume | `masterVolume` | session-only | **persist per-score** |
| Tempo multiplier | `tempoMultiplier` | session-only (engine) | **persist per-score** |
| A4 per-score override | `a4ReferenceHz` | session-only | **persist per-score** |
| Staff program overrides | `staffProgramOverrides` | engine session-only | **persist per-score** |
| Staff volume overrides | `staffVolumeOverrides` | engine session-only | **persist per-score** |
| Repeat mode (per-score? no — global) | `repeatMode` | — | iOS stores mode in the blob too, but the *authoritative* mode is global DataStore on both platforms; Android keeps mode in DataStore. The blob's `repeatMode` is left at default and ignored on Android (documented divergence, no behavior impact). |
| A-B repeat range | `abRepeat` | Room `reader_ab_repeat` ✓ | **fold into the blob** (drop the separate table) |
| **Transpose semitones** | `transposeSemitones` | absent | **persist in blob (UI added, effect later)** |

### Stays transient (parity — iOS also transient)

Mixer mute/solo, A/B pending markers, inspector expand/collapse.

## Architecture

**Approach: shared Domain `ReaderPreferences` is the single source of truth; the
existing `@WireletProvided LibraryStore` plumbing carries the JSON blob to Room; a
new `@WireletObservable` bridge projects typed values to Compose.** This matches
the iOS data model exactly and reuses the Library Android persistence pattern
already in the repo.

```
        ┌─────────────────── shared Swift (Domain) ───────────────────┐
        │  ReaderPreferences  (Codable, clamping in init)             │
        │  ReaderPreferencesStore  (load / seed / mutate→normalize)   │  ← shared with iOS
        └───────────────┬───────────────────────────┬─────────────────┘
                        │ iOS                        │ Android
        loadReaderPreferences /            FolinoReaderPreferences JNI bridge
        saveReaderPreferences              (@WireletObservable + @WireletExpose)
        via ScoreLibraryRepository                  │
        (GRDB columns)                              │  loadReaderPreferencesJSON(scoreId): String?
                                                    │  saveReaderPreferencesJSON(scoreId, json)
                                                    ▼
                                       @WireletProvided LibraryStore  (Swift-declared)
                                                    ▼
                                       RoomLibraryStore (Kotlin)
                                       reader_preferences(score_id PK, json TEXT)
                                                    ▼
                                       Compose inspectors / display bind to bridge fields
```

### 1. Shared model & store (Swift, mostly existing)

- `ReaderPreferences` (Domain) is unchanged — it already has every field including
  `transposeSemitones`. Its `init` is the **one** place clamping/normalization lives,
  shared by both platforms. No Kotlin re-implementation of any rule.
- `ReaderPreferencesStore` (`load/seed/mutate`) currently lives in the Reader
  feature (iOS). It is Foundation-only and depends only on a repository abstraction.
  Two options for sharing it to Android — **decide in the plan**:
  - (a) Reuse the same `ScoreLibraryRepository.loadReaderPreferences/saveReaderPreferences`
    contract on Android, backed by the JSON bridge. Maximum reuse.
  - (b) Keep a thin Android-side Swift store in the JNI module that encodes/decodes
    `ReaderPreferences` JSON directly. Less coupling to the iOS repository protocol.
  - Recommendation: (b) for the bridge module to avoid pulling the full iOS
    repository graph into the Android Reader JNI target; the *normalization* (the
    shared logic that matters) is in `ReaderPreferences.init` either way.

### 2. Persistence transport (`LibraryStore` wirelet — additive)

Add two **String-typed** methods to the Swift-declared `@WireletProvided LibraryStore`
interface (String args sidestep the known wirelet codegen friction with Int/dict
projections):

```
func loadReaderPreferencesJSON(scoreId: String) -> String?   // nil = none stored
func saveReaderPreferencesJSON(scoreId: String, json: String)
```

Kotlin `RoomLibraryStore` implements them against a new entity:

```kotlin
@Entity(tableName = "reader_preferences")
data class ReaderPreferencesEntity(
    @PrimaryKey @ColumnInfo(name = "score_id") val scoreId: String,
    val json: String,
)
```

The blob is **opaque to Kotlin** — Room is a rule-free backend (same philosophy as
the existing `ScoreRecordWire` store). All shape/clamping lives in shared Swift.
The existing `reader_ab_repeat` table + DAO is removed; A-B range now lives inside
the blob's `abRepeat` field (pre-release destructive reset handles the schema change).

### 3. Compose binding (`@WireletObservable ReaderPreferencesBridge`, new Swift)

A per-open-score observable that wraps the decoded `ReaderPreferences` and exposes
**typed, scalar** fields + `@WireletExpose` scalar mutators. Per-staff dictionaries
are never wire-projected as maps; instead they are addressed by **scalar per-staff
calls**, which the wirelet codegen handles cleanly:

- Observable scalars: `staffSize`, `honorLayoutBreaks`, `masterVolume`,
  `tempoMultiplier` (0 sentinel = "no override" → maps to `nil`), `a4ReferenceHz`
  (0 sentinel = inherit global), `transposeSemitones`.
- Observable small lists (for restore/render): `hiddenStaves`, `clefOverrides`,
  `programOverrides`, `volumeOverrides` — each a list of wire structs already used
  by `LayoutOptionsWire` (`HiddenStaffWire`, `ClefOverrideWire`, and two new
  `ProgramOverrideWire`/`VolumeOverrideWire` mirroring them).
- `@WireletExpose` mutators (each re-seats through `ReaderPreferences.init` then
  persists via `saveReaderPreferencesJSON`):
  `setStaffSize`, `setHonorLayoutBreaks`, `setStaffHidden(part,staff,Bool)`,
  `setClef(part,staff,raw)`, `setMasterVolume`, `setTempoMultiplier`,
  `setA4ReferenceHz`, `setTranspose(Int)`, `setStaffProgram(part,staff,Int)`,
  `setStaffVolume(part,staff,Double)`.
- `open(scoreId, defaultStaffSize)` → `loadOrSeed` then publishes fields.

### 4. Per-staff key mapping (engine flat index ↔ StaffAddress)

The display side is already `StaffAddress(partIndex, staffIndexInPart)`-keyed on
Android (`LayoutOptions.kt`). The **mixer** addresses staves by the engine's flat
`MixerChannel.staffIndex`. The persisted blob keys program/volume overrides by
`StaffAddress` (byte-identical to iOS). Therefore the inspector must map
`staffIndex ↔ StaffAddress` at the persistence boundary:

- Build the map from the same parts→staves enumeration `ReaderViewModel.kt`
  already uses to assign `StaffAddress(partIndex, staffIndex)` (the engine's channel
  order is the flat enumeration order).
- On **change**: `MixerRow.onProgram/onVolume` → look up `StaffAddress` for the row's
  `staffIndex` → call `bridge.setStaffProgram(part, staff, …)` (persists) **and**
  `engine.setStaffProgram(staffIndex, …)` (live).
- On **reopen** (after `prepare`): for each persisted override, map `StaffAddress →
  staffIndex` and replay into the engine — exactly where `ReaderPlaybackService`
  already re-applies channel state on hot-swap.

**Risk:** the engine channel-order ↔ enumeration-order assumption must hold. The
plan verifies it against `MixerChannel` and adds a guard (skip overrides whose
`StaffAddress` doesn't resolve) so a mismatch degrades gracefully instead of
mis-applying.

### 5. Load / seed / apply flow on reader open

1. Screen opens score `id` → `bridge.open(id, defaultStaffSize = globalStaffSize)`.
2. Bridge `loadOrSeed`: decode stored JSON, or seed defaults (and persist the seed).
3. Display: `LayoutOptions` is built from the bridge fields (staffSize, hiddenStaves,
   honorLayoutBreaks, clefOverrides) instead of the global DataStore flows.
4. Playback: seed `ReaderAudioViewModel`'s master volume / tempo / A4 from the bridge;
   `applyLoop` restores `abRepeat`; after `prepare`, replay mixer overrides into the engine.
5. Every user change calls the matching bridge mutator (persists) and the existing
   live target (engine / layout recompute).

### 6. Global additions (plain DataStore, no bridge)

- `playlistContinuationMode: Flow<String>` + `setPlaylistContinuationMode(String)` in
  `SettingsPrefs` (default `"playThrough"`, matching iOS `PlaylistContinuationMode`).
- Metronome inspector toggle: `ReaderAudioViewModel._metronomeEnabled` is replaced by
  reading/writing the global `SettingsPrefs.metronome` flow (the engine is still pushed
  the value live; only the source of truth moves from session to the global pref).

## New Settings UI (parity, persist-only effect)

### Playlist continuation — Settings screen

A new row under "Reader" mirroring the existing `RepeatModePicker` pattern: a label
+ segmented/menu picker with the three `PlaylistContinuationMode` cases
(`off` / `playThrough` / `loopPlaylist`), bound to the new DataStore key. Copy/labels
match iOS (`reader.settings.playlistContinuation.*` localization keys → Android
`strings.xml` equivalents). No playback wiring — selecting a value only persists it.

### Transpose — playback inspector

A new row in the "General" group of `PlaybackInspectorSheet`, mirroring iOS
`TransposeRow`: `arrow.up.arrow.down`/`SwapVert`-style icon + "Transpose" label +
signed readout (`+3` / `0` / `-2`, monospaced, tap-to-reset) + a ±1 stepper bounded
to `-7…7`. Bound to `bridge.setTranspose`. **No engine/notation effect** — the value
is persisted for the future transpose feature; the row is functional only insofar as
it remembers and displays the value. The plan adds a code comment marking the
deferred effect.

## Testing

- **Domain (shared, already exists):** `ReaderPreferencesTests` cover clamping/round-trip
  — no change needed; confirm `transposeSemitones` and the JSON encoding are covered.
- **Swift bridge:** unit-test `loadOrSeed` seeding, mutator → normalize → persist
  round-trips, and the 0-sentinel ↔ `nil` mapping for tempo/A4.
- **Kotlin:** Room DAO round-trip for `reader_preferences`; `StaffAddress ↔ staffIndex`
  map derivation from a representative parts/staves descriptor.
- **Manual (Pixel/emulator, per the Android workflow):** set every per-score control,
  close + reopen the score → values restored; set a different score → independent
  (proves per-score scope); set globals → shared across scores; confirm the new
  playlist-continuation picker and transpose stepper persist across app restart.

## Phasing (one spec, staged plan)

- **Phase 1 — Persistence infrastructure + already-UI'd per-score settings.**
  `LibraryStore` wire methods, Room `reader_preferences`, `ReaderPreferencesBridge`,
  load/seed/apply flow. Migrate master volume, tempo, per-score A4, mixer
  program/volume, staff size, hidden staves, honor breaks, clef overrides, and
  A-B range onto the blob. Bind inspector metronome to the global key.
- **Phase 2 — New parity settings UI.** `playlistContinuationMode` DataStore key +
  Settings picker; transpose stepper in the playback inspector. Both persist-only.

Each phase ends with an Android `installDebug` + launch verification on a device/emulator.

## Risks & Open Questions

1. **Engine channel order ↔ StaffAddress enumeration** (see §4). Primary risk;
   verified + guarded in the plan.
2. **Wirelet codegen** for the new per-staff scalar mutators and the two new wire
   structs. Mitigation: all mutator args are scalars/Strings; wire structs reuse the
   proven `HiddenStaffWire`/`ClefOverrideWire` shape. Regenerate codegen → rebuild
   `.so` in the documented order (codegen before `.so`, per prior Android learnings).
3. **`repeatMode` in the blob is unused on Android** (mode is authoritative in
   DataStore). Documented divergence; the field stays at default in the JSON and is
   ignored on load. No behavior impact, keeps the blob byte-shape shared with iOS.
4. **Store-sharing choice (§1 a vs b)** is deferred to the plan; both share the
   normalization, which is the parity-critical part.
