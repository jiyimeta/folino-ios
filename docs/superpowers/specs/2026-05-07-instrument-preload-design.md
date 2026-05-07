# Inspector Instrument Cache-Aware Preload — Design

## Problem

Picking an instrument from the Reader's Inspector menu calls
`ReaderViewModel.setPartProgram(_:forPartIndex:)`, which forwards to
`PlaybackController.setStaffInstrument(staff:bank:program:)`. The live
controller invokes `engine.setProgram(...)` immediately. If the precise
SF2 file for the new `(bank, program, isDrums)` triple is not yet on
disk, the engine's resolver falls back to a bundled patch — the user
hears the wrong instrument with no warning.

The score-open flow already handles this: `prepareForPlayback` calls
`controller.load(score:preferences:)`, which prefetches every distinct
patch the score needs, and `togglePlayback` shows a "loading playback
sounds…" / "you're offline" alert when the cache misses. The Inspector
instrument-pick path needs the same treatment, scoped to the single
patch the user just selected.

## Goals

1. Picking a cache-miss instrument from the Inspector menu kicks off a
   prefetch for that single patch, mirroring the score-open prefetch.
2. If the user presses Play before the prefetch finishes, the existing
   alert appears (`.loading` online, `.offline` otherwise).
3. If the user picks a cache-miss instrument while playback is already
   running, the alert appears immediately, playback pauses, and after
   the prefetch completes playback resumes automatically with the new
   instrument applied.
4. Cancelling the alert mid-prefetch reverts the menu selection to the
   previous program.

## Non-Goals

- No change to score-open prefetch or to the score-level fallback rewrite.
- No queueing UI for multiple in-flight instrument prefetches; only the
  most recent selection per part is honored (Q3 below).
- No partial download progress UI. The alert remains a yes/no modal
  with a Cancel button, matching the existing flow.

## Architecture

### `Domain.PlaybackController` — two new methods

```swift
/// True iff the soundfont for this triple is already on disk (bundled
/// or cached). Mirrors `areSoundfontsAvailableLocally(for:)` but at
/// the per-patch granularity the Inspector needs.
func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) async -> Bool

/// Download and cache a single patch. Resolves on success; throws on
/// `Task.cancel()` or resolver failure. Idempotent — a no-op if the
/// patch is already cached.
func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) async throws
```

`LivePlaybackController` implements both as thin adapters over the
existing `domainResolver` (`cachedPatches()` / `resolveSoundfont(...)`).

### `ReaderViewModel` — pending-load state

```swift
private struct PendingInstrumentLoad {
    let partIndex: Int
    let bank: Int
    let program: Int
    let isDrums: Bool
    let previousOverrides: [StaffAddress: Int?]  // address → prior override (nil == unset)
    let wasPlaying: Bool                          // resume after success
    let task: Task<Void, Error>
}

@ObservationIgnored
private var pendingInstrumentLoad: PendingInstrumentLoad?
```

`previousOverrides` is per-staff because clearing the override and
setting the override to a different value are distinct revert paths.

### `setPartProgram` — new flow

```
setPartProgram(newProgram, partIndex):
  guard score loaded, controller available, part has staves
  bank, isDrums = part.instrument.channel.{bank, useDrumset}

  cached = await controller.isSoundfontCached(bank, newProgram, isDrums)
  if cached:
    // Existing path: persist override + push to engine immediately.
    return await applyProgramSynchronously(newProgram, partIndex)

  // Cache miss path
  if let existing = pendingInstrumentLoad,
     existing.partIndex == partIndex,
     existing.program == newProgram:
    return  // duplicate — let the in-flight task finish

  // Q3: a different in-flight pick on the same part loses to this one.
  //     Cancel it; its catch branch reverts its preferences mutation
  //     before our new previousOverrides snapshot is taken. We also
  //     inherit its `wasPlaying` flag — if the user was playing when
  //     they kicked off the first pick, we already paused them and the
  //     cancel-revert leaves us paused; the *new* pick should still
  //     auto-resume on success because that was the original intent.
  inheritedWasPlaying = false
  if let existing = pendingInstrumentLoad, existing.partIndex == partIndex:
    inheritedWasPlaying = existing.wasPlaying
    existing.task.cancel()
    _ = try? await existing.task.value   // let revert run

  previousOverrides = snapshot of preferences.staffProgramOverrides
                      restricted to this part's StaffAddresses
  await mutatePreferences { ... set newProgram for every staff address }

  wasPlaying = isPlaying || inheritedWasPlaying
  if isPlaying:
    await controller.pause(); isPlaying = false
  if wasPlaying:
    soundfontAlertKind = (await reachability.isOnline()) ? .loading : .offline

  task = Task { try await controller.prefetchSoundfont(bank, newProgram, isDrums) }
  pendingInstrumentLoad = PendingInstrumentLoad(..., task)

  do:
    try await task.value
    // Success: push to engine, then resume if we paused.
    for address in part.staves:
      await controller.setStaffInstrument(staff: flat, bank, newProgram)
    soundfontAlertKind = nil
    pendingInstrumentLoad = nil
    if wasPlaying:
      try? await controller.play()
      isPlaying = true
  catch:
    // Cancel or resolver failure → revert per-staff overrides to snapshot.
    await mutatePreferences { restore previousOverrides }
    soundfontAlertKind = nil
    pendingInstrumentLoad = nil
    // Q1 A only resumes on success. Cancel leaves us paused.
```

`applyProgramSynchronously` is the current body of `setPartProgram` —
mutate preferences, fan out `setStaffInstrument` to each staff in the
part. Extracted so the cached path stays a one-liner.

### `togglePlayback` — wait for in-flight instrument prefetch

A new branch fires before the existing `!hasLoadedIntoPlayback` block:

```
if let pending = pendingInstrumentLoad, !pending.wasPlaying:
  // Prefetch was kicked off silently (user wasn't playing). Now they
  // want to play — surface the same alert and wait for it.
  let online = await reachability?.isOnline() ?? true
  soundfontAlertKind = online ? .loading : .offline
  do:
    try await pending.task.value
    soundfontAlertKind = nil
    // Engine reflection happens in the prefetch task's success closure
    // inside setPartProgram — we just need to wait. Fall through to
    // the normal play path.
  catch:
    soundfontAlertKind = nil
    return  // user cancelled or resolver failed; revert handled in setPartProgram
```

Edge case: if `pendingInstrumentLoad` exists *and* `!hasLoadedIntoPlayback`,
the engine prep path runs after this branch, in the same `togglePlayback`
call. That's the score-just-opened-with-pending-pick case. Both waits are
sequential.

### `cancelLoadingSoundfonts`

Extends to cancel both tasks:

```swift
public func cancelLoadingSoundfonts() {
    preloadTask?.cancel()
    pendingInstrumentLoad?.task.cancel()
}
```

The View layer's existing alert binding works unchanged — it just calls
`cancelLoadingSoundfonts` on dismissal.

## Data Flow Summary

| Trigger                                 | wasPlaying | cached | Result                                                                                |
|-----------------------------------------|------------|--------|---------------------------------------------------------------------------------------|
| Inspector pick                          | false      | true   | Persist + push to engine immediately. No alert. (Current behavior.)                   |
| Inspector pick                          | false      | false  | Persist (UI shows new pick), start prefetch silently. No alert until Play pressed.    |
| Inspector pick                          | true       | true   | Persist + push to engine immediately. (Current behavior.)                             |
| Inspector pick                          | true       | false  | Persist, pause, show alert, prefetch, push to engine, resume play.                    |
| Play tapped during silent prefetch      | —          | —      | Alert appears, await task, then normal play start.                                    |
| Cancel tapped during alert              | —          | —      | Cancel task → revert preferences → alert dismisses → playback stays paused.           |

## Error Handling

- `prefetchSoundfont` throwing (network failure, file IO) → caught in
  `setPartProgram`'s catch branch → revert + dismiss alert. Same path
  as user cancellation; no separate copy.
- `isSoundfontCached` is a query — no throws on the protocol. The live
  implementation already swallows `cachedPatches()` errors and returns
  `false` (matches existing `areSoundfontsAvailableLocally` behavior).

## Tests

New `@Test` cases in `ReaderViewModelPlaybackTests`:

1. `setPartProgramWithCachedPatchSkipsPrefetchAndAppliesImmediately` —
   `controller.cachedPrograms` contains the target → no `prefetchCount`
   bump, `staffInstrumentCalls` records the change synchronously, no
   alert.
2. `setPartProgramWithUncachedPatchPrefetchesSilentlyWhenNotPlaying` —
   prefetch starts, no alert, `pendingInstrumentLoad != nil` until task
   resolves.
3. `togglePlaybackDuringSilentInstrumentPrefetchShowsLoadingAlert` —
   silent prefetch in flight → `togglePlayback` sets `.loading`, awaits,
   then plays.
4. `togglePlaybackDuringSilentPrefetchShowsOfflineAlertWhenOffline` —
   same but `reachability.online == false`.
5. `setPartProgramDuringPlaybackPausesAndShowsAlertImmediately` —
   `wasPlaying == true`, cache miss → engine paused, alert visible
   before task resolves.
6. `setPartProgramDuringPlaybackResumesAfterPrefetchSucceeds` —
   covers Q1 A: `controller.playCount` increments after task resolves
   and `staffInstrumentCalls` records the change.
7. `cancelDuringInstrumentPrefetchRevertsProgramOverride` —
   covers Q2 A: `cancelLoadingSoundfonts` → preferences revert to
   pre-pick state, no `staffInstrumentCalls` for the cancelled program.
8. `secondInstrumentPickCancelsFirstAndKeepsOriginalAsRevertTarget` —
   covers Q3: A→B (uncached) then A→C while B is in flight; cancelling
   C reverts to A, not B.
8a. `secondInstrumentPickInheritsWasPlayingFromFirstPick` —
    Playing → A→B (paused, alert) → A→C while B is in flight; C succeeds
    → playback resumes (wasPlaying inherited from B even though
    `isPlaying == false` at the moment of the C pick).
9. `setPartProgramOnUncachedPatchKeepsPlayingFalseUntilSuccess` —
   `wasPlaying == false`, prefetch in flight → `isPlaying` stays false
   throughout, `playCount == 0` even on success.

`FakePlaybackController` additions:

```swift
var cachedPatches: Set<PatchKey> = []   // (bank, program, isDrums)
private(set) var prefetchedPatches: [PatchKey] = []
var blocksPrefetchUntilCancelled: Bool = false

func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) -> Bool { ... }
func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) async throws { ... }
```

`LivePlaybackControllerTests` additions:

- `prefetchSoundfontResolvesPatchAndPopulatesCache` — drives a fake
  `Domain.SoundfontResolver` with one patch, asserts `resolveSoundfont`
  was called and `isSoundfontCached` flips to true.
- `isSoundfontCachedReturnsTrueAfterPatchIsResolved` — same setup,
  pre-resolves, asserts cache hit.

## Open Questions

None — Q1 (auto-resume), Q2 (revert on cancel), Q3 (latest pick wins)
all confirmed in brainstorming.

## File Changes

- `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift` —
  add the two new method requirements.
- `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` —
  implement the two new methods.
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` —
  add `PendingInstrumentLoad`, restructure `setPartProgram`, branch
  in `togglePlayback`, extend `cancelLoadingSoundfonts`.
- `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift` —
  add prefetch / cache state.
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift` —
  9 new `@Test` cases.
- `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift` —
  2 new `@Test` cases.

No changes to localization (existing alert copy is reused) or to the
Inspector view (the menu still calls the same `setPartProgram` entry
point).
