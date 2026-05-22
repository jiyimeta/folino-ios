# Reader View Model Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract `ReaderPiPSession`, `ReaderPlaybackSession`, and `ReaderPreferencesStore` from `ReaderViewModel` so the file's `// swiftlint:disable file_length` and `// swiftlint:disable:next type_body_length` suppressions can be removed, while keeping behavior identical.

**Architecture:** Pure refactor. Three new `@MainActor` classes own responsibility-shaped slices of the current view model. The view model becomes a thin orchestrator that wires the subsystems through provider closures and `onChange` / `onX` callbacks — same pattern as the existing `RepeatModel` / `TempoModel` / `LayoutSettingsModel` / `PlaybackMixerModel` sub-models. No new product behavior. Existing reader test suite is the safety net — it must stay green between commits.

**Tech Stack:** Swift 6.3 / iOS 26+, `@Observable`, Swift Testing, SwiftPM-only iteration via `swift test` from inside `Packages/Features/Reader/`.

**Spec:** `docs/superpowers/specs/2026-05-22-reader-view-model-split-design.md`

**Strategy:** Three extraction passes, each one a self-contained green commit. After all three, migrate view call sites (Sources + Tests) in one sweep, then remove the SwiftLint suppressions.

---

## Conventions for this plan

- All `cd` into `Packages/Features/Reader/` for `swift test` is absolute: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader`.
- The repo root is `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS`. All file paths below are relative to this root.
- "Run reader tests" means: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader && swift test`.
- Per project CLAUDE.md: this is a refactor, so each commit MUST leave reader tests green. If they break, fix in the same commit — do not advance.
- Per project CLAUDE.md: `swiftlint --fix` runs in the pre-commit hook against staged Swift files. Do not partial-stage (`git add -p`).
- Per project CLAUDE.md: new tests use Swift Testing. Existing tests stay on their current framework when modified.
- Each extraction keeps **VM forwarder methods** in place temporarily so views and tests continue to compile. The forwarders are deleted at the very end (Task 4) when view + test call sites are migrated in one sweep.

---

## File Structure

**New files:**
- `Packages/Features/Reader/Sources/Reader/ReaderPreferencesStore.swift` (Task 1)
- `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift` (Task 2)
- `Packages/Features/Reader/Sources/Reader/PiP/ReaderPiPSession.swift` (Task 3)

**Modified files:**
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — touched in every task; ends at ~200 lines.
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` — Task 4
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift` — Task 4
- `Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalZoomedSurface.swift` — Task 4
- `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalZoomedSurface.swift` — Task 4
- `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedZoomedSurface.swift` — Task 4
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelHiddenStaffCursorTests.swift` — Task 4
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelManualCursorTests.swift` — Task 4
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift` — Task 4
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift` — Task 4
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelSoundfontSwapTests.swift` — Task 4
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTempoTests.swift` — Task 4
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift` — Task 4
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPartProgramTests.swift` — Task 4 (only if it references the migrated members)

---

## Task 1 — Extract `ReaderPreferencesStore`

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/ReaderPreferencesStore.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`

### Step 1.1 — Capture baseline (sanity check)

- [ ] Run reader tests to confirm a green baseline.

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader
swift test
```

Expected: all tests pass. If anything is red here, stop and surface it — the plan assumes a green starting state.

### Step 1.2 — Create `ReaderPreferencesStore.swift`

- [ ] Write the new file exactly as below.

`Packages/Features/Reader/Sources/Reader/ReaderPreferencesStore.swift`:

```swift
import Domain
import Foundation

/// Loads, seeds, and persists `ReaderPreferences` for a single `ScoreItem`. The store re-runs
/// `ReaderPreferences.init` after every mutation so the type's clamping rules always apply, and
/// it never reaches into the view model's sub-models — distribution of loaded preferences is the
/// caller's job (see `ReaderViewModel.load()`).
@MainActor
final class ReaderPreferencesStore {
    private(set) var preferences: ReaderPreferences

    private let repository: any ScoreLibraryRepository
    private let scoreItemID: ScoreItem.ID
    private let defaultStaffSize: CGFloat

    init(
        scoreItemID: ScoreItem.ID,
        defaultStaffSize: CGFloat,
        repository: any ScoreLibraryRepository,
    ) {
        self.scoreItemID = scoreItemID
        self.defaultStaffSize = defaultStaffSize
        self.repository = repository
        preferences = ReaderPreferences(
            scoreItemID: scoreItemID,
            staffSize: defaultStaffSize,
            hiddenStaves: [],
        )
    }

    /// Loads the persisted preferences if any, otherwise seeds defaults and writes them through. Either way
    /// the resolved value lands in `preferences` and is returned for the caller to distribute into sub-models.
    @discardableResult
    func loadOrSeed() async -> ReaderPreferences {
        do {
            if let stored = try await repository.loadReaderPreferences(for: scoreItemID) {
                preferences = stored
                return stored
            }
        } catch {
            // Persistence error is non-fatal; fall through to seed defaults.
        }
        let seeded = ReaderPreferences(
            scoreItemID: scoreItemID,
            staffSize: defaultStaffSize,
            hiddenStaves: [],
        )
        preferences = seeded
        try? await repository.saveReaderPreferences(seeded)
        return seeded
    }

    /// Applies `apply` to a working copy, then re-seats through `ReaderPreferences.init` so clamping rules
    /// always run. The normalized value lands in `preferences` and is persisted.
    func mutate(_ apply: (inout ReaderPreferences) -> Void) async {
        var copy = preferences
        apply(&copy)
        let normalized = ReaderPreferences(
            id: copy.id,
            scoreItemID: copy.scoreItemID,
            staffSize: copy.staffSize,
            hiddenStaves: copy.hiddenStaves,
            staffProgramOverrides: copy.staffProgramOverrides,
            staffVolumeOverrides: copy.staffVolumeOverrides,
            staffClefOverrides: copy.staffClefOverrides,
            tempoMultiplier: copy.tempoMultiplier,
            honorLayoutBreaks: copy.honorLayoutBreaks,
            repeatMode: copy.repeatMode,
            abRepeat: copy.abRepeat,
        )
        preferences = normalized
        try? await repository.saveReaderPreferences(normalized)
    }
}
```

### Step 1.3 — Wire the store into `ReaderViewModel`

- [ ] Open `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`.

- [ ] Replace the `preferences` stored property and `repository` storage usage so the store owns persistence. Specifically:

  Replace the existing line:
  ```swift
  private(set) var preferences: ReaderPreferences
  ```
  with:
  ```swift
  /// Persistence-of-record for `ReaderPreferences`. Sub-models observe their own state; this store is the
  /// single mutator and the source of truth for re-normalization.
  @ObservationIgnored private let preferencesStore: ReaderPreferencesStore

  /// Convenience accessor for code paths that need the current preferences value (e.g. building
  /// `PlaybackPreferences.initial` at engine load time).
  var preferences: ReaderPreferences { preferencesStore.preferences }
  ```

  Note: `preferences` is now a computed accessor. The View Model no longer holds a stored copy.

- [ ] In `init`, replace the `preferences = ReaderPreferences(...)` initialization with construction of the store:

  Replace:
  ```swift
  preferences = ReaderPreferences(
      scoreItemID: scoreItem.id,
      staffSize: defaultStaffSize,
      hiddenStaves: [],
  )
  ```
  with:
  ```swift
  preferencesStore = ReaderPreferencesStore(
      scoreItemID: scoreItem.id,
      defaultStaffSize: defaultStaffSize,
      repository: repository,
  )
  ```

- [ ] Delete the entire private `mutatePreferences(_:)` method (lines ~555–574 in the current file). Its body has moved into the store.

- [ ] Replace every `await mutatePreferences { prefs in ... }` call inside `wireMixerModel`, `wireLayoutModel`, `wireTempoModel`, `wireRepeatModel` with `await preferencesStore.mutate { prefs in ... }`. The closure bodies stay identical.

- [ ] Replace the private `loadOrSeedPreferences()` method body so it delegates to the store and distributes the result to the sub-models. The new body:

  ```swift
  private func loadOrSeedPreferences() async {
      let prefs = await preferencesStore.loadOrSeed()
      repeatModel.sync(from: prefs)
      tempoModel.sync(from: prefs)
      layoutModel.sync(from: prefs)
      mixerModel.sync(from: prefs)
  }
  ```

  This replaces the existing 25-line implementation that handled the load/seed branching inline.

### Step 1.4 — Verify

- [ ] Run reader tests.

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader
swift test
```

Expected: PASS — same set as the baseline.

### Step 1.5 — Commit

- [ ] Stage and commit.

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderPreferencesStore.swift
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
git commit -m "$(cat <<'EOF'
Extract ReaderPreferencesStore from ReaderViewModel

Persistence-of-record for ReaderPreferences moves to a dedicated
store that re-runs ReaderPreferences.init for clamping. The view
model keeps a computed `preferences` accessor and delegates load
and mutate paths to the store.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If the pre-commit hook reports formatting changes, re-stage the same files and re-commit. Do NOT use `--amend` after a hook failure (per project CLAUDE.md).

---

## Task 2 — Extract `ReaderPlaybackSession`

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`

### Step 2.1 — Create `ReaderPlaybackSession.swift`

- [ ] Write the new file exactly as below.

`Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift`:

```swift
import Domain
import Foundation
import Observation
import SheetMusicCore

/// Owns engine load/play/pause lifecycle, cursor stream subscription with hidden-staves translation, and
/// the high-quality soundfont hot-swap watcher. Created and wired by `ReaderViewModel`; views observe
/// `isPlaying` and `playbackCursor` through `viewModel.playbackSession`.
@MainActor
@Observable
final class ReaderPlaybackSession {
    private(set) var isPlaying = false
    private(set) var playbackCursor: ScoreCursor?

    @ObservationIgnored private(set) var rawPlaybackCursor: ScoreCursor?

    @ObservationIgnored let controller: (any PlaybackController)?

    @ObservationIgnored private let museScoreGeneralProvider: (any MuseScoreGeneralProvider)?
    @ObservationIgnored private var hasLoadedIntoPlayback = false
    @ObservationIgnored private var preloadTask: Task<Void, Error>?
    @ObservationIgnored private var pendingSoundfontSwap = false
    @ObservationIgnored private var soundfontDownloadTask: Task<Void, Never>?

    /// Providers — set by the owner (`ReaderViewModel`) right after init.
    var scoreProvider:        () -> Score?              = { nil }
    var hiddenStavesProvider: () -> Set<StaffIndex>     = { [] }
    var preferencesProvider:  () -> ReaderPreferences?  = { nil }
    var scoreItemProvider:    () -> ScoreItem?          = { nil }

    /// Callbacks — fired after state transitions so the owner can fan out to PiP / repeat / etc.
    var onPlayingChanged:      (Bool) -> Void      = { _ in }
    var onCursorChanged:       () -> Void          = {}
    var onReadyForLoopForward: () async -> Void    = {}

    init(
        controller: (any PlaybackController)?,
        museScoreGeneralProvider: (any MuseScoreGeneralProvider)?,
    ) {
        self.controller = controller
        self.museScoreGeneralProvider = museScoreGeneralProvider
    }

    deinit {
        soundfontDownloadTask?.cancel()
    }

    /// Kick off the engine load in the background. Idempotent — re-entry while loading or already loaded
    /// is a no-op. Cancellation is forwarded into the unstructured task so a Reader dismiss mid-prep
    /// doesn't keep the engine churning.
    func prepareForPlayback() async {
        guard let controller,
              let score = scoreProvider(),
              let prefs = preferencesProvider(),
              let scoreItem = scoreItemProvider(),
              !hasLoadedIntoPlayback,
              preloadTask == nil
        else { return }
        let initial = PlaybackPreferences.initial(
            for: score,
            readerPreferences: prefs,
            scoreItemID: scoreItem.id,
            defaultVolume: ReaderViewModel.defaultStaffVolume,
        )
        let task = Task<Void, Error> { [scoreItem] in
            try await controller.load(
                score: score, displayTitle: scoreItem.title, preferences: initial,
            )
        }
        preloadTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            hasLoadedIntoPlayback = true
            // PlaybackPreferences carries `abRepeat` but the engine's load path doesn't consume it.
            // Push the active loop range now that the score is loaded.
            await onReadyForLoopForward()
        } catch {
            // Cancellation or controller error — leave the slot clear so a subsequent toggle starts a
            // fresh attempt.
        }
        preloadTask = nil
    }

    /// Tear down the audio engine and reset prepare-state so the system's auto-lock can take effect once
    /// the Reader is off-screen.
    func releaseEngine() async {
        preloadTask?.cancel()
        preloadTask = nil
        await controller?.releaseEngine()
        hasLoadedIntoPlayback = false
    }

    func togglePlayback() async {
        guard let controller,
              let score = scoreProvider(),
              let prefs = preferencesProvider(),
              let scoreItem = scoreItemProvider()
        else { return }
        if !hasLoadedIntoPlayback {
            let initial = PlaybackPreferences.initial(
                for: score,
                readerPreferences: prefs,
                scoreItemID: scoreItem.id,
                defaultVolume: ReaderViewModel.defaultStaffVolume,
            )
            let task = preloadTask ?? Task<Void, Error> { [scoreItem] in
                try await controller.load(
                    score: score, displayTitle: scoreItem.title, preferences: initial,
                )
            }
            preloadTask = task
            do {
                try await task.value
                hasLoadedIntoPlayback = true
            } catch {
                preloadTask = nil
                return
            }
            // Push the persisted repeat state now that the engine has the score — covers the case where
            // the user taps play before prepareForPlayback finished.
            await onReadyForLoopForward()
            preloadTask = nil
        }
        if isPlaying {
            await controller.pause()
            setPlaying(false)
        } else {
            do {
                try await controller.play()
                setPlaying(true)
            } catch {
                setPlaying(false)
            }
        }
    }

    /// Subscribe to the controller's cursor stream. Must be called from a view-lifecycle hook
    /// (`.task` / `.onAppear`) — NOT from `init` — so only the session that SwiftUI actually retains
    /// via `@State` registers its handler.
    func startObservingCursor() {
        guard let controller else { return }
        controller.observeCursor { [weak self] value in
            guard let self else { return }
            rawPlaybackCursor = value
            applyCursorTranslation(value)
            // The engine emits a nil cursor only when playback hits the end of the score
            // (PlaybackEngine.stop() clears it; explicit pause() does not). Use that signal to flip
            // the toolbar's play/pause glyph back to "play".
            if value == nil, isPlaying {
                setPlaying(false)
            }
        }
        controller.observeIsPlaying { [weak self] playing in
            guard let self else { return }
            setPlaying(playing)
            if !playing, pendingSoundfontSwap {
                pendingSoundfontSwap = false
                Task { await self.controller?.reloadSoundfont() }
            }
        }
    }

    /// Watch the high-quality soundfont download. If it finishes while the Reader is open, hot-swap the
    /// engine's SF2 without forcing the user to reopen the score — swap immediately when paused, or
    /// queue until the next pause when actively playing. One-shot per Reader session.
    func startObservingSoundfontDownload() {
        guard let provider = museScoreGeneralProvider,
              soundfontDownloadTask == nil
        else { return }
        // Already downloaded at Reader open → the natural controller.load(...) will pick up the
        // high-quality SF2 on its own, no swap needed.
        if case .downloaded = provider.downloadState { return }
        soundfontDownloadTask = Task { @MainActor [weak self] in
            let stream = Observations { provider.downloadState }
            for await state in stream {
                guard let self else { return }
                if case .downloaded = state {
                    handleSoundfontReady()
                    return
                }
            }
        }
    }

    func setManualCursor(_ cursor: ScoreCursor) {
        let hidden = hiddenStavesProvider()
        let engineCursor = scoreProvider()?.engineCursorForFilteredTap(
            cursor,
            hiddenStaves: hidden,
        ) ?? cursor
        rawPlaybackCursor = engineCursor
        playbackCursor = cursor
        onCursorChanged()
        guard let controller else { return }
        Task { await controller.setCursor(to: engineCursor) }
    }

    /// Re-translate `rawPlaybackCursor` against the current hidden-staves set. Called by the owner
    /// after `LayoutSettingsModel.onHiddenStavesChanged`.
    func refreshTranslation() {
        applyCursorTranslation(rawPlaybackCursor)
    }

    // MARK: - Private

    private func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        onPlayingChanged(playing)
    }

    private func applyCursorTranslation(_ raw: ScoreCursor?) {
        let translated = scoreProvider()?.translateCursorForHiddenStaves(
            raw,
            hiddenStaves: hiddenStavesProvider(),
        ) ?? raw
        playbackCursor = translated
        onCursorChanged()
    }

    private func handleSoundfontReady() {
        // Engine hasn't been primed yet → prepareForPlayback / togglePlayback will consume the new
        // resolver URL on its initial load, so nothing to do here.
        guard hasLoadedIntoPlayback else { return }
        if isPlaying {
            pendingSoundfontSwap = true
        } else {
            Task { await controller?.reloadSoundfont() }
        }
    }
}
```

Notes for the engineer:
- `ReaderViewModel.defaultStaffVolume` stays on the view model (static). The session reads it through the existing type reference.
- `applyCursorTranslation` always emits `onCursorChanged` so the owner can notify PiP. Idempotent emission is fine — the PiP path is a single coordinator update.
- `setPlaying` guards on transition so `onPlayingChanged` doesn't fire on no-op stream events.

### Step 2.2 — Wire the session into `ReaderViewModel`

- [ ] Open `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`.

- [ ] Remove these stored properties from the view model:
  - `private(set) var isPlaying = false` (and its `didSet`)
  - `private(set) var playbackCursor: ScoreCursor?`
  - `let playbackController: (any PlaybackController)?` (the `@ObservationIgnored let`)
  - `private let museScoreGeneralProvider: (any MuseScoreGeneralProvider)?`
  - `private var hasLoadedIntoPlayback = false`
  - `private var preloadTask: Task<Void, Error>?`
  - `private var pendingSoundfontSwap = false`
  - `private var soundfontDownloadObservationTask: Task<Void, Never>?`
  - `private var rawPlaybackCursor: ScoreCursor?`

- [ ] Add a new stored property:
  ```swift
  var playbackSession: ReaderPlaybackSession
  ```

- [ ] In `init`, construct the session right after `preferencesStore` is built:

  ```swift
  playbackSession = ReaderPlaybackSession(
      controller: playbackController,
      museScoreGeneralProvider: museScoreGeneralProvider,
  )
  ```

- [ ] After the four existing `wire*Model()` calls in `init`, add a new private method invocation and method body:

  ```swift
  wirePlaybackSession()
  ```

  ```swift
  private func wirePlaybackSession() {
      playbackSession.scoreProvider = { [weak self] in self?.loadState.score }
      playbackSession.hiddenStavesProvider = { [weak self] in self?.layoutModel.hiddenStaves ?? [] }
      playbackSession.preferencesProvider = { [weak self] in self?.preferencesStore.preferences }
      playbackSession.scoreItemProvider = { [weak self] in self?.scoreItem }
      playbackSession.onPlayingChanged = { [weak self] playing in
          // Temporarily a no-op — PiP arm-on-play wiring lands in Task 3.
          _ = playing
          _ = self
      }
      playbackSession.onCursorChanged = { [weak self] in
          // Temporarily a no-op — PiP cursor-notify wiring lands in Task 3.
          _ = self
      }
      playbackSession.onReadyForLoopForward = { [weak self] in
          await self?.repeatModel.forwardLoopRangeToController()
      }
  }
  ```

- [ ] Update `wireLayoutModel`'s `onHiddenStavesChanged` to call `playbackSession.refreshTranslation()` instead of inlining the translation:

  Replace:
  ```swift
  layoutModel.onHiddenStavesChanged = { [weak self] in
      guard let self else { return }
      playbackCursor = loadState.score?.translateCursorForHiddenStaves(
          rawPlaybackCursor,
          hiddenStaves: layoutModel.hiddenStaves,
      ) ?? rawPlaybackCursor
      notifyPiPCursor()
      if isPiPActive {
          pipCoordinator.dismissIfActive()
      }
  }
  ```
  with:
  ```swift
  layoutModel.onHiddenStavesChanged = { [weak self] in
      guard let self else { return }
      playbackSession.refreshTranslation()
      // PiP dismiss-on-layout-change moves into Task 3's wiring; keep the existing inline call so
      // behavior is identical mid-extraction.
      if isPiPActive {
          pipCoordinator.dismissIfActive()
      }
  }
  ```

- [ ] Delete the view model's `prepareForPlayback()`, `releaseEngine()`, `togglePlayback()`, `startObservingCursor()`, `startObservingSoundfontDownload()`, `handleSoundfontReady()`, `notifyPiPCursor()`, and `setManualCursor(_:)` method bodies — they have moved to the session.

- [ ] Add **temporary forwarder** methods so existing view + test call sites keep compiling. Place them in a single `// MARK: - Temporary forwarders (deleted in Task 4)` block near the bottom of the type:

  ```swift
  // MARK: - Temporary forwarders (deleted in Task 4)

  var isPlaying: Bool { playbackSession.isPlaying }
  var playbackCursor: ScoreCursor? { playbackSession.playbackCursor }

  func prepareForPlayback() async { await playbackSession.prepareForPlayback() }
  func releaseEngine() async { await playbackSession.releaseEngine() }
  func togglePlayback() async { await playbackSession.togglePlayback() }
  func startObservingCursor() { playbackSession.startObservingCursor() }
  func startObservingSoundfontDownload() { playbackSession.startObservingSoundfontDownload() }
  func setManualCursor(_ cursor: ScoreCursor) { playbackSession.setManualCursor(cursor) }
  ```

- [ ] Update the existing `notifyPiPCursor()` call site inside `pipCoordinator`'s `currentTimeProvider` block — the PiP coordinator still lives in the view model at this point. Specifically, the view model's `pipCoordinator` lazy initializer references `playbackController` directly. Replace those direct references with `playbackSession.controller`:

  ```swift
  c.currentTimeProvider = { [weak self] in
      self?.playbackSession.controller?.currentTimeSeconds ?? 0
  }
  c.totalTimeProvider = { [weak self] in
      self?.playbackSession.controller?.totalTimeSeconds ?? 0
  }
  c.onSkip = { [weak self] seconds in
      guard let controller = self?.playbackSession.controller else { return }
      Task { await controller.skip(bySeconds: seconds) }
  }
  ```

  And the `onSetPlaying` closure inside `pipCoordinator`:
  ```swift
  c.onSetPlaying = { [weak self] desired in
      guard let self, playbackSession.isPlaying != desired else { return }
      Task { await self.playbackSession.togglePlayback() }
  }
  c.isAppPlayingProvider = { [weak self] in self?.playbackSession.isPlaying ?? false }
  ```

  Also update `applyPiPAutoStart`:
  ```swift
  private func applyPiPAutoStart() {
      guard isPiPSupported else { return }
      pipCoordinator.setAutoStartFromBackground(isPiPEnabled && playbackSession.isPlaying)
  }
  ```

  And `armPiPIfReady`:
  ```swift
  private func armPiPIfReady() {
      guard isPiPEnabled, case .loaded = loadState else { return }
      if !hasArmedPiP || isPiPActive || playbackSession.isPlaying {
          scheduleArm()
      } else {
          pipArmIsDirty = true
      }
  }
  ```

  And `performPiPArm` — it currently reads `playbackCursor` directly; change to `playbackSession.playbackCursor`.

  Also delete the view model's `deinit { soundfontDownloadObservationTask?.cancel() }` — that responsibility moved into `ReaderPlaybackSession.deinit`.

  And update `playbackSession.onPlayingChanged` (in `wirePlaybackSession` above) to call the PiP-side reactions that previously lived in `isPlaying.didSet`:

  ```swift
  playbackSession.onPlayingChanged = { [weak self] playing in
      guard let self else { return }
      applyPiPAutoStart()
      if playing { flushPendingPiPArmIfDirty() }
  }
  ```

  And update `onCursorChanged`:
  ```swift
  playbackSession.onCursorChanged = { [weak self] in
      self?.pipCoordinatorBacking?.updatePlaybackCursor(self?.playbackSession.playbackCursor)
  }
  ```

### Step 2.3 — Verify

- [ ] Run reader tests.

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader
swift test
```

Expected: PASS — same set as the baseline. If a test now references a member that moved (e.g. `vm.isPlaying` works via forwarder but a test directly inspects a private member that was deleted), surface it; the forwarders should cover all current public usage.

### Step 2.4 — Commit

- [ ] Stage and commit.

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
git commit -m "$(cat <<'EOF'
Extract ReaderPlaybackSession from ReaderViewModel

The engine load/play/pause lifecycle, cursor stream subscription
with hidden-staves translation, and soundfont hot-swap watcher move
into a dedicated session. The view model keeps temporary forwarders
for isPlaying / playbackCursor / togglePlayback / setManualCursor /
prepareForPlayback / releaseEngine / startObservingCursor /
startObservingSoundfontDownload until Task 4 migrates call sites.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — Extract `ReaderPiPSession`

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/PiP/ReaderPiPSession.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`

### Step 3.1 — Create `ReaderPiPSession.swift`

- [ ] Write the new file exactly as below.

`Packages/Features/Reader/Sources/Reader/PiP/ReaderPiPSession.swift`:

```swift
import CoreGraphics
import Domain
import Foundation
import Observation
import SheetMusicCore

/// Snapshot of the layout inputs that determine PiP arm shape. Built by the view model at arm time so
/// every arm sees a consistent staffSize / hiddenStaves / clefOverrides triple, even if the user is
/// toggling staves rapidly.
struct PiPLayoutSnapshot {
    let staffSize: CGFloat
    let hiddenStaves: Set<StaffIndex>
    let clefOverrides: [StaffIndex: ClefSign]
}

/// Wraps `ScorePiPCoordinator` with the session-lifecycle policy that previously lived inline in
/// `ReaderViewModel`: arm coalescing, dirty tracking when no observer would see the result, autostart
/// permission gating on `isPlaying`, and forced dismiss when AVKit-cached aspect ratios go stale.
@MainActor
@Observable
final class ReaderPiPSession {
    private(set) var isActive = false

    @ObservationIgnored private var coordinatorBacking: ScorePiPCoordinator?
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var collapseMultiMeasureRests = false
    @ObservationIgnored private var pendingArmTask: Task<Void, Never>?
    @ObservationIgnored private var hasArmed = false
    @ObservationIgnored private var isDirty = false

    /// Providers — set by the owner (`ReaderViewModel`) right after init.
    var scoreProvider:           () -> Score?              = { nil }
    var isPlayingProvider:       () -> Bool                = { false }
    var playbackCursorProvider:  () -> ScoreCursor?        = { nil }
    var layoutSnapshotProvider:  () -> PiPLayoutSnapshot?  = { nil }
    var playbackController:      (any PlaybackController)?

    /// Triggered when the PiP HUD's play/pause button fires. The owner forwards into
    /// `playbackSession.togglePlayback()`.
    var onTogglePlayback: () async -> Void = {}

    static var isSupported: Bool { ScorePiPCoordinator.isSupported }

    var coordinator: ScorePiPCoordinator {
        if let c = coordinatorBacking { return c }
        let c = ScorePiPCoordinator()
        c.onPiPStarted = { [weak self] in self?.isActive = true }
        c.onPiPStopped = { [weak self] in self?.isActive = false }
        c.isAppPlayingProvider = { [weak self] in self?.isPlayingProvider() ?? false }
        c.onSetPlaying = { [weak self] desired in
            guard let self, isPlayingProvider() != desired else { return }
            Task { await self.onTogglePlayback() }
        }
        c.currentTimeProvider = { [weak self] in
            self?.playbackController?.currentTimeSeconds ?? 0
        }
        c.totalTimeProvider = { [weak self] in
            self?.playbackController?.totalTimeSeconds ?? 0
        }
        c.onSkip = { [weak self] seconds in
            guard let controller = self?.playbackController else { return }
            Task { await controller.skip(bySeconds: seconds) }
        }
        coordinatorBacking = c
        return c
    }

    func setEnabled(_ enabled: Bool) {
        guard Self.isSupported else { return }
        isEnabled = enabled
        applyAutoStart()
        if enabled {
            armIfReady()
        } else {
            pendingArmTask?.cancel()
            pendingArmTask = nil
            isDirty = false
            hasArmed = false
            dismissIfActive()
            coordinator.disarm()
        }
    }

    func setCollapseMultiMeasureRests(_ enabled: Bool) {
        guard collapseMultiMeasureRests != enabled else { return }
        collapseMultiMeasureRests = enabled
        armIfReady()
    }

    /// No-ops when not active. Called from the Reader scenePhase observer on foreground return AND
    /// from the hidden-staves change handler (so AVKit renegotiates the PiP window aspect ratio on
    /// the next auto-start).
    func dismissIfActive() {
        guard isActive else { return }
        coordinator.dismissIfActive()
    }

    /// Owner calls this after `playbackSession.playbackCursor` updates.
    func notifyCursorChanged() {
        coordinatorBacking?.updatePlaybackCursor(playbackCursorProvider())
    }

    /// Owner calls this after `playbackSession.isPlaying` flips.
    func onPlayingChanged(to playing: Bool) {
        applyAutoStart()
        if playing { flushDirtyIfNeeded() }
    }

    /// Coalesced rearm trigger. The heavy layout step inside `coordinator.arm` runs off the main
    /// actor, but it's wasted CPU when no observer would see the result. In that case the arm is
    /// postponed; `flushDirtyIfNeeded` consumes the postponement when an observer appears.
    ///
    /// The first arm of each `isEnabled` session always proceeds so a manual PiP start (via the
    /// system control) still finds a renderer attached.
    func armIfReady() {
        guard isEnabled, scoreProvider() != nil else { return }
        if !hasArmed || isActive || isPlayingProvider() {
            scheduleArm()
        } else {
            isDirty = true
        }
    }

    // MARK: - Private

    private func scheduleArm() {
        isDirty = false
        pendingArmTask?.cancel()
        pendingArmTask = Task { [weak self] in
            guard let self else { return }
            await performArm()
        }
    }

    private func flushDirtyIfNeeded() {
        guard isDirty else { return }
        scheduleArm()
    }

    private func performArm() async {
        guard !Task.isCancelled,
              isEnabled,
              let score = scoreProvider(),
              let snapshot = layoutSnapshotProvider()
        else { return }
        let visible = score
            .applying(clefOverrides: snapshot.clefOverrides)
            .filtered(hidingStaves: snapshot.hiddenStaves)
        do {
            try await coordinator.arm(
                score: visible,
                staffSize: snapshot.staffSize,
                playbackCursor: playbackCursorProvider(),
                collapseMultiMeasureRests: collapseMultiMeasureRests,
            )
            hasArmed = true
        } catch is CancellationError {
            // Superseded by a newer rearm; nothing to do.
        } catch {
            // Coordinator throws only when no display layer is attached (the host view hasn't
            // mounted yet). Arming will retry once the view installs the layer and load() finishes —
            // neither ordering is fatal.
        }
    }

    private func applyAutoStart() {
        guard Self.isSupported else { return }
        coordinator.setAutoStartFromBackground(isEnabled && isPlayingProvider())
    }
}
```

### Step 3.2 — Wire the session into `ReaderViewModel`

- [ ] Open `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`.

- [ ] Remove the inline PiP state from the view model (these properties + the lazy `pipCoordinator`):
  - `var isPiPActive = false`
  - `private var pipCoordinatorBacking: ScorePiPCoordinator?`
  - `var pipCoordinator: ScorePiPCoordinator { ... }` (entire lazy block)
  - `private var isPiPEnabled = false`
  - `private var collapseMultiMeasureRests = false`
  - `private var pendingArmTask: Task<Void, Never>?`
  - `private var hasArmedPiP = false`
  - `private var pipArmIsDirty = false`

- [ ] Remove the inline PiP methods from the view model:
  - `setPiPEnabled(_:)`, `applyPiPAutoStart()`, `setCollapseMultiMeasureRests(_:)`
  - `dismissPiPOnForeground()`, `armPiPIfReady()`, `scheduleArm()`
  - `flushPendingPiPArmIfDirty()`, `performPiPArm()`, `notifyPiPCursor()`
  - `var isPiPSupported: Bool` (replaced via temporary forwarder below)

- [ ] Add a new stored property:
  ```swift
  var pipSession: ReaderPiPSession
  ```

- [ ] In `init`, construct the PiP session right after `playbackSession`:

  ```swift
  pipSession = ReaderPiPSession()
  ```

- [ ] Add a `wirePiPSession()` invocation in `init` right after `wirePlaybackSession()`, and the method body:

  ```swift
  private func wirePiPSession() {
      pipSession.scoreProvider = { [weak self] in self?.loadState.score }
      pipSession.isPlayingProvider = { [weak self] in self?.playbackSession.isPlaying ?? false }
      pipSession.playbackCursorProvider = { [weak self] in self?.playbackSession.playbackCursor }
      pipSession.layoutSnapshotProvider = { [weak self] in self?.currentPiPLayoutSnapshot() }
      pipSession.playbackController = playbackSession.controller
      pipSession.onTogglePlayback = { [weak self] in await self?.playbackSession.togglePlayback() }
  }

  private func currentPiPLayoutSnapshot() -> PiPLayoutSnapshot {
      PiPLayoutSnapshot(
          staffSize: layoutModel.staffSize,
          hiddenStaves: layoutModel.hiddenStaves,
          clefOverrides: layoutModel.staffClefOverrides,
      )
  }
  ```

- [ ] Update `wirePlaybackSession` so `onPlayingChanged` and `onCursorChanged` now fan out to the PiP session (this replaces the temporary `applyPiPAutoStart` / `flushPendingPiPArmIfDirty` / inline notify shapes from Task 2):

  ```swift
  playbackSession.onPlayingChanged = { [weak self] playing in
      self?.pipSession.onPlayingChanged(to: playing)
  }
  playbackSession.onCursorChanged = { [weak self] in
      self?.pipSession.notifyCursorChanged()
  }
  ```

- [ ] Update `wireLayoutModel`'s callbacks so the PiP arm-on-clef-change and dismiss-on-hidden-staves-change paths go through the session:

  Replace the `onChange` callback's `armPiPIfReady()` call with `pipSession.armIfReady()`.

  Replace `onHiddenStavesChanged`'s body so it is:
  ```swift
  layoutModel.onHiddenStavesChanged = { [weak self] in
      guard let self else { return }
      playbackSession.refreshTranslation()
      pipSession.dismissIfActive()
  }
  ```

- [ ] Update `load()` so it calls `pipSession.armIfReady()` instead of `armPiPIfReady()`.

- [ ] Add temporary forwarder methods so existing view + test call sites keep compiling (extend the Task-2 forwarder block):

  ```swift
  // MARK: - Temporary forwarders (deleted in Task 4)
  // ... existing playback forwarders from Task 2 ...

  var isPiPSupported: Bool { ReaderPiPSession.isSupported }
  var isPiPActive: Bool { pipSession.isActive }

  func setPiPEnabled(_ enabled: Bool) { pipSession.setEnabled(enabled) }
  func setCollapseMultiMeasureRests(_ enabled: Bool) {
      pipSession.setCollapseMultiMeasureRests(enabled)
  }
  func dismissPiPOnForeground() { pipSession.dismissIfActive() }
  ```

### Step 3.3 — Verify

- [ ] Run reader tests.

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader
swift test
```

Expected: PASS — same set as the baseline.

### Step 3.4 — Commit

- [ ] Stage and commit.

```bash
git add Packages/Features/Reader/Sources/Reader/PiP/ReaderPiPSession.swift
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
git commit -m "$(cat <<'EOF'
Extract ReaderPiPSession from ReaderViewModel

The PiP session policy (enable/disable, arm coalescing, dirty
tracking, autostart gating, dismiss-on-foreground) moves into a
dedicated session that wraps ScorePiPCoordinator. The view model
keeps temporary forwarders for isPiPSupported / isPiPActive /
setPiPEnabled / setCollapseMultiMeasureRests / dismissPiPOnForeground
until Task 4 migrates call sites.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — Migrate view + test call sites, remove forwarders, remove SwiftLint suppressions

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalZoomedSurface.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalZoomedSurface.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedZoomedSurface.swift`
- Modify: tests under `Packages/Features/Reader/Tests/ReaderTests/` (listed below)

### Step 4.1 — Migrate Sources call sites

Apply these exact renamings. Use the project structure unchanged.

- [ ] `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`:

  | Before | After |
  | --- | --- |
  | `viewModel.isPiPSupported` | `ReaderPiPSession.isSupported` |
  | `viewModel.startObservingCursor()` | `viewModel.playbackSession.startObservingCursor()` |
  | `viewModel.startObservingSoundfontDownload()` | `viewModel.playbackSession.startObservingSoundfontDownload()` |
  | `viewModel.setPiPEnabled(...)` | `viewModel.pipSession.setEnabled(...)` |
  | `viewModel.setCollapseMultiMeasureRests(...)` | `viewModel.pipSession.setCollapseMultiMeasureRests(...)` |
  | `await viewModel.prepareForPlayback()` | `await viewModel.playbackSession.prepareForPlayback()` |
  | `await viewModel.releaseEngine()` | `await viewModel.playbackSession.releaseEngine()` |
  | `viewModel.dismissPiPOnForeground()` | `viewModel.pipSession.dismissIfActive()` |
  | `viewModel.playbackCursor` | `viewModel.playbackSession.playbackCursor` |

- [ ] `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift`:

  | Before | After |
  | --- | --- |
  | `viewModel.isPlaying` (both occurrences) | `viewModel.playbackSession.isPlaying` |
  | `await viewModel.togglePlayback()` | `await viewModel.playbackSession.togglePlayback()` |

- [ ] `Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalZoomedSurface.swift`:

  | Before | After |
  | --- | --- |
  | `viewModel.setManualCursor(cursor)` | `viewModel.playbackSession.setManualCursor(cursor)` |

- [ ] `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalZoomedSurface.swift`:

  Same as Horizontal.

- [ ] `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedZoomedSurface.swift`:

  Same as Horizontal.

### Step 4.2 — Migrate test call sites

Tests use `vm` as the local name. Apply the same renames.

- [ ] In each test file under `Packages/Features/Reader/Tests/ReaderTests/`, rewrite the following identifiers:

  | Before | After |
  | --- | --- |
  | `vm.isPlaying` | `vm.playbackSession.isPlaying` |
  | `vm.playbackCursor` | `vm.playbackSession.playbackCursor` |
  | `vm.togglePlayback()` | `vm.playbackSession.togglePlayback()` |
  | `vm.setManualCursor(` | `vm.playbackSession.setManualCursor(` |
  | `vm.prepareForPlayback()` | `vm.playbackSession.prepareForPlayback()` |
  | `vm.startObservingCursor()` | `vm.playbackSession.startObservingCursor()` |
  | `vm.startObservingSoundfontDownload()` | `vm.playbackSession.startObservingSoundfontDownload()` |

  Files known to need the migration (run `grep -l "vm\.\(isPlaying\|playbackCursor\|togglePlayback\|setManualCursor\|prepareForPlayback\|startObservingCursor\|startObservingSoundfontDownload\)" Packages/Features/Reader/Tests/ReaderTests/*.swift` to confirm before editing):

  - `ReaderViewModelHiddenStaffCursorTests.swift`
  - `ReaderViewModelManualCursorTests.swift`
  - `ReaderViewModelPlaybackTests.swift`
  - `ReaderViewModelRepeatTests.swift`
  - `ReaderViewModelSoundfontSwapTests.swift`
  - `ReaderViewModelTempoTests.swift`
  - `ReaderViewModelTests.swift`

  If `ReaderViewModelPartProgramTests.swift` does not reference any migrated identifier, leave it alone.

### Step 4.3 — Remove the temporary forwarders from `ReaderViewModel.swift`

- [ ] Delete the entire `// MARK: - Temporary forwarders (deleted in Task 4)` block introduced in Tasks 2 and 3.

### Step 4.4 — Remove the SwiftLint suppressions

- [ ] Open `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`.

- [ ] Delete the `// swiftlint:disable file_length` directive at the top of the file.

- [ ] Delete the `// swiftlint:disable:next type_body_length` directive immediately above `final class ReaderViewModel`.

### Step 4.5 — Verify file is now within budget

- [ ] Confirm the file count is under the SwiftLint thresholds.

```bash
wc -l Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
```

Expected: under 400 lines (SwiftLint warning threshold per `.swiftlint.yml`). The target shape from the spec is ~200 lines.

### Step 4.6 — Verify the project lints clean

- [ ] Run SwiftLint against the package source tree.

```bash
swiftlint lint --quiet --strict Packages/Features/Reader/Sources/Reader/
```

Expected: no warnings or errors. If `file_length` or `type_body_length` warnings fire on `ReaderViewModel.swift`, the extraction is incomplete — surface the offending line count and revisit Tasks 1–3 (do not re-add suppressions).

### Step 4.7 — Verify tests still pass

- [ ] Run reader tests.

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader
swift test
```

Expected: PASS.

### Step 4.8 — Verify the app builds

- [ ] Run the project-level build to confirm nothing outside Reader broke.

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED.

### Step 4.9 — Commit

- [ ] Stage and commit.

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
git add Packages/Features/Reader/Sources/Reader/Screens/
git add Packages/Features/Reader/Tests/ReaderTests/
git commit -m "$(cat <<'EOF'
Migrate Reader views and tests to new session call sites

Views now address ReaderPlaybackSession and ReaderPiPSession
directly via viewModel.playbackSession / viewModel.pipSession. The
temporary forwarders introduced during Tasks 2 and 3 are removed,
and the file_length / type_body_length suppressions on
ReaderViewModel.swift drop now that the orchestrator fits inside
the default SwiftLint budget.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] Reader tests: green.
- [ ] SwiftLint: clean for `Packages/Features/Reader/Sources/Reader/`.
- [ ] Full app build: SUCCEEDED.
- [ ] `ReaderViewModel.swift` is under 400 lines and contains no `swiftlint:disable` directives.
- [ ] Spot-check at runtime (per project CLAUDE.md, UI verification preferred via SwiftUI preview where possible): open a score, toggle play/pause, enable PiP, background mid-playback, hide a staff, change a clef, hit AB-repeat. Behavior must match `main` exactly.

## Notes for the implementer

- Refactor discipline: behavior preservation is the explicit acceptance criterion. If a test fails, the new code is wrong — do not relax the test.
- The four existing sub-models (`Repeat/Tempo/LayoutSettings/PlaybackMixer`) are not touched. If a step seems to ask you to modify one, re-read the task — it should only be reading from them via providers or callbacks.
- `[weak self]` is mandatory in every closure that crosses session ↔ view model. The view model owns all three sessions; sessions must never strongly retain the view model.
- Do not split commits by hunk (project CLAUDE.md). Stage whole files.
- Do not use `--amend` after a pre-commit hook failure (project CLAUDE.md). Re-stage and create a new commit.
