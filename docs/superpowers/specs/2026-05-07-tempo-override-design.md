# Tempo Override in Mixer

Lets the user scale playback tempo in the Reader's Mixer pane and persists the chosen multiplier per score. Also surfaces the metronome on/off toggle that already exists on `Domain.PlaybackController` but has no UI.

## Goals

- Add a master row to `MixerView` with a metronome icon (tap = on/off) and a percentage-tagged tempo slider.
- Persist the tempo override on `ReaderPreferences` (per score). Persist metronome on/off globally.
- Reflect tempo changes on the playback engine immediately while the user is dragging.

## Non-Goals

- Absolute BPM display, BPM picker, tempo automation curves.
- Per-staff tempo (single master multiplier only).
- Migrating any persisted data — `tempoMultiplier` on `ReaderPreferences` is added as `Optional`, so existing rows decode with `nil` for free.

## Data Model

### `Domain.ReaderPreferences`

Add:

```swift
public var tempoMultiplier: Double?   // nil = no override; clamped to [0.5, 2.0]
```

- `nil` means "no override" — the engine plays at the score's native tempo (multiplier 1.0).
- Non-nil values are clamped in the initializer to `[0.5, 2.0]`.
- Save-time normalization in `ReaderViewModel`: a value of exactly `1.0` is stored as `nil`. Avoids carrying redundant overrides forever once the user resets.

### `Domain.PlaybackPreferences`

Unchanged. Already carries `tempoMultiplier: Double` (clamped `[0.5, 2.0]`, default 1.0). Continues to be the seed-time channel from Reader to engine; `ReaderViewModel.initialPlaybackPreferences` passes `preferences.tempoMultiplier ?? 1.0`.

### Metronome on/off (global)

`@AppStorage("readerMetronomeEnabled")` — `Bool`, default `false`. Same pattern as the existing global Reader layout mode (per `ReaderPreferences.swift` doc comment). Not persisted on `ReaderPreferences`.

## Engine Surface (`swift-sheet-music`)

`SheetMusicAudio.PlaybackEngine` currently keeps `sequencer: AVAudioSequencer?` private, with no public rate API. Add:

```swift
public func setRate(_ rate: Float)
```

Implementation:

- Stores the value in `private var pendingRate: Float = 1.0`.
- If `sequencer` is non-nil, writes `sequencer.rate = pendingRate` immediately.
- After every sequencer rebuild (`buildSequencer` finishes), reapplies `pendingRate` so the override survives prepare-on-different-score and play-from-cursor restarts.

The metronome track is attached to the same sequencer (`metronome.attach(to: sequencer)` in `buildSequencer`), so metronome timing follows `sequencer.rate` automatically — no separate scaling.

This is a one-commit change in `jiyimeta/swift-sheet-music` and a SwiftPM revision bump in Folino's `Package.swift` files (Domain, Infrastructure, Reader) plus `project.yml`.

## Domain Adapter

`Infrastructure/Audio/LivePlaybackController.swift` line 191 currently has:

```swift
public func setTempoMultiplier(_: Double) {}
```

Replace with:

```swift
public func setTempoMultiplier(_ value: Double) {
    engine.setRate(Float(value))
}
```

`load(score:preferences:)` also applies `preferences.tempoMultiplier` once at seed time so the engine has the correct rate before the first `play()`.

## ReaderViewModel API

Added in `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`:

```swift
/// Effective multiplier for UI rendering — falls back to 1.0 when no override.
public var effectiveTempoMultiplier: Double { preferences.tempoMultiplier ?? 1.0 }

/// While the user is dragging: forward to the engine immediately, do NOT persist.
public func setTempoMultiplier(_ value: Double)

/// On drag end: persist (normalizing 1.0 → nil) and forward.
public func commitTempoMultiplier(_ value: Double) async

/// Tap on the % label: persist nil, forward 1.0.
public func resetTempoMultiplier() async

/// Forward metronome on/off to the engine. Persistence is owned by the View
/// layer via @AppStorage("readerMetronomeEnabled") so it survives across scores.
public func setMetronomeEnabled(_ enabled: Bool) async
```

Persistence path uses the existing `mutatePreferences` helper. `mutatePreferences` re-seats through `ReaderPreferences.init`, which both clamps the value and exercises the save path — same pattern as program overrides.

`mutatePreferences` itself needs one tweak: it currently rebuilds the struct field-by-field, dropping any field not enumerated. Add `tempoMultiplier: copy.tempoMultiplier` to the rebuild call.

## UI (`MixerView.swift`)

A single master row at the top of the `List`, above the per-part sections:

```
[ 🥁 ] [ 100% ] ━━━━━━●━━━━━━━━━━
  ↑       ↑                ↑
  tap     tap          continuous
  on/off  reset         0.5 … 2.0
```

- **Icon button:** `Image(systemName: isMetronomeOn ? "metronome.fill" : "metronome")`. Tap toggles `@AppStorage("readerMetronomeEnabled")` and calls `viewModel.setMetronomeEnabled`.
- **Percentage label:** `"\(Int((multiplier * 100).rounded()))%"`, monospaced digits, fixed minimum width so the slider doesn't jiggle when the value changes. Tap → `await viewModel.resetTempoMultiplier()`.
- **Slider:** `Slider(value: $localTempo, in: 0.5...2.0, onEditingChanged: { editing in ... })`. While editing, calls `setTempoMultiplier`; on release, calls `commitTempoMultiplier`.

Local UI state holds the slider value; the source of truth for the persisted/effective value remains `viewModel.effectiveTempoMultiplier`. Sync the local state from the view model when not actively editing (e.g. when the view model resets via the % tap).

Section placement: a new top-of-list `Section` with no header, sibling to the per-part sections. Falls within the existing `.listStyle(.plain)` container.

## Testing

### Domain (`DomainTests`)

- `ReaderPreferences` clamps `tempoMultiplier` to `[0.5, 2.0]` (lower, upper, in-range, nil pass-through).
- Round-trip `Codable` — `tempoMultiplier == nil` encodes as a missing key (or null) and decodes back to `nil`; existing JSON without the key decodes successfully.

### Reader feature (`ReaderTests`)

Using the existing fake repository / fake controller pattern:

- `setTempoMultiplier` does NOT call `saveReaderPreferences`; DOES call `controller.setTempoMultiplier`.
- `commitTempoMultiplier(0.75)` saves with `tempoMultiplier == 0.75`; calls controller.
- `commitTempoMultiplier(1.0)` saves with `tempoMultiplier == nil` (normalization).
- `resetTempoMultiplier` saves with `nil` and calls controller with `1.0`.
- Out-of-range commit (e.g. `commitTempoMultiplier(3.0)`) is clamped to `2.0` on save (via `ReaderPreferences.init`).
- `setMetronomeEnabled(true)` calls `controller.setMetronomeEnabled(true)`; does NOT touch `saveReaderPreferences`.

### Manual / preview verification

- Render the existing `#Preview` in `MixerView.swift` — confirm the master row layout (icon, %, slider) matches the mock.
- Build the app for the simulator, open a score, drag the slider while playing — audio should speed up/slow down without skipping. Toggle the metronome icon during playback — clicks start/stop.

## Out-of-Repo Coordination

`swift-sheet-music` change must land first (its own PR/commit). After that:

1. Bump the `from:` version in Folino's three `Package.swift` files (`Domain`, `Infrastructure`, `Features/Reader`) and the matching entry in `project.yml`.
2. `xcodegen generate`.
3. The remaining changes stay inside this repo.

## Risks / Notes

- `AVAudioSequencer.rate` is documented to take effect on the next render — empirically smooth in the SheetMusicExample app, but worth eyeballing during the manual verification step.
- `metronome.fill` SF Symbol exists from iOS 17 (we target iOS 26), no fallback needed.
- The slider doesn't quantize; user can land on `0.99` or `1.01` and the % label will show `99%` / `101%`. That's fine — the reset tap is the canonical way to get back to exactly 100%.
