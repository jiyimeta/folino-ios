# Staff Volume — MSCX Default + Persisted Override

Replace the Reader's hard-coded `1.0` per-staff volume with an mscx-sourced default, and persist the user's slider adjustment as a per-score override that survives across sessions.

## Goals

- Initial slider value for each staff comes from the score's MSCX `<controller ctrl="7" value="N"/>` (CC7), mapped from `0...127` to `0...1` — same source the `swift-sheet-music` `SheetMusicExample` already uses for its mixer.
- Slider commit persists `staffVolumeOverrides[address]` on `ReaderPreferences`. Drag updates only nudge the engine; DB writes happen on release.
- Engine seeding (`initialPlaybackPreferences`) consumes the same merged value (`override ?? mscxDefault`).

## Non-Goals

- Reset-to-default UI. Picked **D** in brainstorming Q1 — once an override is set, it stays. We ship without a "reset" button and revisit only if it turns out to be needed.
- Persistence of mute / solo. Both stay in-memory. Out of scope.
- Backwards compatibility with pre-release dev DBs. The app has not shipped, so a v5 additive migration is sufficient; we don't try to backfill from any prior format.
- Volume on the metronome strip. Metronome volume isn't surfaced in Folino's Inspector today and we're not adding it here.

## Source of Truth — Where Each Layer Reads From

```
Slider rendering:    ReaderViewModel.volume(for:)
                     = liveStaffVolumes[address]
                       ?? preferences.staffVolumeOverrides[address]
                       ?? scoreDefaultVolume(for: address)   // CC7 / 127
                       ?? Self.defaultStaffVolume            // 1.0 fallback

Engine seed (load):  ReaderViewModel.initialPlaybackPreferences(for:)
                     = preferences.staffVolumeOverrides[address]
                       ?? scoreDefaultVolume(for: address)
                       ?? Self.defaultStaffVolume
                     (no `liveStaffVolumes` lookup — engine seed only happens
                      before the user can drag.)

DB row:              reader_preferences.staff_volume_overrides   (TEXT JSON)
```

`scoreDefaultVolume(for:)` on the VM mirrors the `swift-sheet-music` formula:

```swift
private func scoreDefaultVolume(for address: StaffAddress) -> Double? {
    guard
        case let .loaded(score) = loadState,
        score.parts.indices.contains(address.partIndex)
    else { return nil }
    let cc7 = score.parts[address.partIndex].instrument.channel.volume
    let clamped = max(0, min(127, cc7))
    return Double(clamped) / 127.0
}
```

## Data Model

### `Domain.ReaderPreferences`

Add:

```swift
public var staffVolumeOverrides: [StaffAddress: Double]
```

- `init` clamps each value to `[0, 1]` (parallel to how `staffProgramOverrides` clamps to `[0, 127]`).
- Default is `[:]`.
- Place the parameter immediately after `staffProgramOverrides` in the initializer.

### `Domain.PlaybackPreferences`

Unchanged. The seeding path on the VM already uses `volume(for:)`-style merging via the `staffVolumes` lookup; we just retarget that lookup at the new override map.

### Persistence

DB migration **v5** added to `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`:

```swift
private static func migrateV5(_ db: Database) throws {
    try db.execute(sql: """
    ALTER TABLE reader_preferences
    ADD COLUMN staff_volume_overrides TEXT NOT NULL DEFAULT '[]'
    """)
}
```

Register `m.registerMigration("v5", migrate: migrateV5)` on `AppMigrations.all`. Add a partial `upToV4` migrator parallel to the existing `upToV2` / `upToV3`, so future v5-step tests can write rows at the v4 schema and exercise the upgrade in isolation.

`ReaderPreferencesRecord` updates:

- New stored field: `var staffVolumeOverrides: String` (JSON triple array, same shape as the program overrides field).
- Encoded form: `[[partIndex, staffIndexInPart, volume], ...]`, sorted by `(partIndex, staffIndexInPart)`. Volume is encoded as `Double`.
- `init(domain:)` writes the new column; `toDomain()` reads triples whose third element is `Double` (`JSONDecoder` decodes `[[Double]]`, then converts the address ints).
- Round-trip test added in `ReaderPreferencesRecordTests`, mirroring the existing program-override test.

## ReaderViewModel API

In `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`:

State changes:

```swift
public static let defaultStaffVolume: Double = 1.0       // unchanged — last-resort fallback
public private(set) var liveStaffVolumes: [StaffAddress: Double] = [:]
// `staffVolumes` (the old observed dict) is removed.
```

Lookup:

```swift
public func volume(for address: StaffAddress) -> Double {
    liveStaffVolumes[address]
        ?? preferences.staffVolumeOverrides[address]
        ?? scoreDefaultVolume(for: address)
        ?? Self.defaultStaffVolume
}
```

Slider drag (no persistence):

```swift
public func setVolume(_ value: Double, for address: StaffAddress) {
    let clamped = min(max(value, 0), 1)
    liveStaffVolumes[address] = clamped
    guard let flat = flattenedStaffIndex(for: address) else { return }
    Task { await playbackController?.setStaffVolume(staff: flat, volume: clamped) }
}
```

Slider release (persist override):

```swift
public func commitVolume(_ value: Double, for address: StaffAddress) async {
    let clamped = min(max(value, 0), 1)
    await mutatePreferences { $0.staffVolumeOverrides[address] = clamped }
    liveStaffVolumes[address] = nil
    guard let flat = flattenedStaffIndex(for: address) else { return }
    await playbackController?.setStaffVolume(staff: flat, volume: clamped)
}
```

Engine seed (`initialPlaybackPreferences`) — replace the `staffVolumes[entry.address] ?? Self.defaultStaffVolume` lookup with:

```swift
let volume = preferences.staffVolumeOverrides[entry.address]
    ?? scoreDefaultVolume(for: entry.address)
    ?? Self.defaultStaffVolume
```

`mutatePreferences` already rebuilds the struct field-by-field; add `staffVolumeOverrides: copy.staffVolumeOverrides` to that rebuild call so the new field round-trips.

## Inspector UI (`InspectorView.swift`)

Today's staff row passes a binding straight into `setVolume`:

```swift
Slider(value: volumeBinding, in: 0...1)
```

Replace with the same drag/commit two-stage pattern tempo uses, but per-staff. Two options:

**Option A — VM-owned live state (chosen).** Keep the binding terse: `setVolume` updates `liveStaffVolumes`, `commitVolume` persists. The `Slider`'s `onEditingChanged` fires `commitVolume` on release.

```swift
@ViewBuilder
private func staffRow(address: StaffAddress) -> some View {
    let volumeBinding = Binding<Double>(
        get: { viewModel.volume(for: address) },
        set: { viewModel.setVolume($0, for: address) }
    )
    Slider(
        value: volumeBinding,
        in: 0...1,
        onEditingChanged: { editing in
            if !editing {
                Task { await viewModel.commitVolume(volumeBinding.wrappedValue, for: address) }
            }
        }
    )
    // … existing solo / mute / visibility buttons unchanged …
}
```

The View doesn't need any new `@State`; reactivity is provided by `liveStaffVolumes` being an observed property on the `@Observable` VM. Under the hood, `volume(for:)` returns the live value during drag, and on release the live entry is cleared and the override takes over — the slider stays at the same on-screen position because the merged value is identical at the boundary.

**Option B (rejected).** View-owned `@State [StaffAddress: Double]` dict. Simpler VM, more verbose View. We pick Option A because it lets the engine seed and tests exercise the same `volume(for:)` lookup path the View already uses.

Disabled state (`.disabled(isMuted || !soloStaves.isEmpty && !isSolo)`) and the surrounding Solo / Mute / visibility buttons are unchanged.

## Engine / Adapter

No changes to `LivePlaybackController` or to `swift-sheet-music`. `setStaffVolume(staff:volume:)` already exists and takes `0...1`. The Reader-side `initialPlaybackPreferences` change is the only seed-time difference, and it's still a `StaffMixerState` whose `volume` field already accepts the same `0...1` range.

## Behaviour Matrix

| State                                                       | `volume(for:)` returns                       | DB value                  |
|-------------------------------------------------------------|----------------------------------------------|---------------------------|
| Fresh score, never opened                                   | `cc7 / 127` (mscx default)                   | row absent, or column `'[]'` |
| Slider being dragged                                        | `liveStaffVolumes[address]`                  | unchanged from before drag   |
| Slider released at value `v`                                | `v` (now from override)                      | `[..., [p, s, v]]`           |
| Slider released exactly on the mscx default value           | `v` (still stored as override; per Q1 = D)   | `[..., [p, s, v]]`           |
| Score reopened, override exists                             | override                                     | persisted override           |
| Score has no `<controller ctrl="7"/>` in mscx (fallback)    | `100/127 ≈ 0.787` from `InstrumentChannel`'s default | column `'[]'`        |
| Score parts list missing for `address` (corrupt score)      | `1.0` (last-resort `defaultStaffVolume`)     | n/a                       |

## Testing

### Domain (`DomainTests/Models/ReaderPreferencesTests.swift`)

- `staffVolumeOverrides` clamps each value to `[0, 1]` (e.g. `-0.5 → 0`, `2.0 → 1`).
- Codable round-trip: `staffVolumeOverrides` survives encode/decode of `ReaderPreferences`.

### Infrastructure (`InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift`)

- New round-trip case: build `ReaderPreferences` with a non-empty `staffVolumeOverrides`, write via `ReaderPreferencesRecord(domain:)`, read back via `toDomain()`, assert equality.
- New migration test: at the `upToV4` schema, write a row, run `migrateV5`, confirm the upgraded row decodes with `staffVolumeOverrides == [:]`.

### Reader feature (`ReaderTests/ReaderViewModelTests.swift`)

Replace the existing `staffVolumeDefaultsToOneAndIsClampedOnSet` test with:

- **mscx default seeding.** Construct a fake score whose part 0 has `InstrumentChannel(volume: 64)`. After load, `vm.volume(for: StaffAddress(0,0))` ≈ `64/127` (within ε).
- **drag does not persist.** `vm.setVolume(0.4, for: address)` ⇒ `vm.volume(for: address) == 0.4`, `vm.preferences.staffVolumeOverrides` is still empty, and the fake repository observed no save.
- **release persists.** `await vm.commitVolume(0.4, for: address)` ⇒ `vm.preferences.staffVolumeOverrides[address] == 0.4`, fake repository observed exactly one save with the new value.
- **clamp on commit.** `await vm.commitVolume(-0.5, for: address)` saves `0`; `await vm.commitVolume(2.0, for: address)` saves `1`. The clamp also runs through `ReaderPreferences.init` (defence in depth).
- **fallback.** When the fake score has no parts for an address, `volume(for:)` returns `1.0`.

### Reader feature — playback wiring (`ReaderTests/ReaderViewModelPlaybackTests.swift`)

- **engine seed uses override over mscx.** `commitVolume(0.3, for: address)`, then drive `prepareForPlayback`, assert the fake controller's `lastLoadedPreferences.perStaff[idx].volume == 0.3`.
- **engine seed uses mscx when no override.** Score with `InstrumentChannel(volume: 80)`, no override, `prepareForPlayback` ⇒ fake controller saw `80/127` (within ε) for that staff.
- **drag forwards to engine but does not persist.** `vm.setVolume(0.5, for: address)` ⇒ `controller.staffVolumes[idx] == 0.5`; preferences saved set unchanged.

### Manual / preview verification

- Open the Inspector preview (existing `#Preview` in `InspectorView.swift`); render via `mcp__xcode__RenderPreview`; confirm slider thumbs sit at the per-staff mscx default rather than full-right at `1.0`.
- For an actual mscx file with non-default CC7 (the tests/fixtures already include one for program-override testing — reuse) build to simulator, confirm the slider seeds match expectations and a slider drag persists across kill-and-relaunch.

## Risks / Notes

- `InstrumentChannel.volume` defaults to `100` when MSCX has no `<controller ctrl="7"/>` for the part — this matches MuseScore's own behaviour, so any score that "looked unity in MuseScore" will now render at `100/127 ≈ 0.787` instead of `1.0`. That's an audible change versus today, but it's the intended UX of "match the score's mix". Worth a release-note line.
- `liveStaffVolumes` lives on the `@Observable` VM and triggers re-render on every `set`. SwiftUI handles this fine for a slider drag (we already do the same via `staffVolumes` today); just noting the property must NOT be `@ObservationIgnored`.
- `mutatePreferences` re-seats the struct through `ReaderPreferences.init`, which means a commit at e.g. `0.4001` is stored exactly as `0.4001` (init does not snap). That's intentional — the slider is continuous, not quantized.
