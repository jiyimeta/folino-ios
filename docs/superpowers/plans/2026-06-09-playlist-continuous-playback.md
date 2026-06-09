# Playlist Continuous Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play a playlist's scores continuously — when one score finishes, advance to and auto-play the next — with a global, sticky three-state control (Off / Continuous / Repeat All) that defaults to Continuous and is subordinate to the per-score repeat feature.

**Architecture:** The decision of "what happens at end of score" is a one-directional ladder enforced partly by the engine itself: when per-score repeat (`loopAll` / `abLoop`) is active the engine holds a loop range and never emits the end-of-score (`cursor == nil`) signal, so advance never fires — repeat always wins. When repeat is off and the Reader was opened from a playlist, a pure Domain function (`PlaylistPlaybackProgression.nextAction`) decides stop / advance / wrap from the live ordered playlist. Advancing is done **in place** inside the existing `ReaderViewModel` (release engine → retarget `scoreItem` → reload → auto-play), so there is **no advance-side navigation change**; only the *open* path gains a `playlistID` so the Reader knows which playlist it is traversing.

**Tech Stack:** Swift 6.3, SwiftUI, `@Observable` view models, `@AppStorage` (global settings via `ReaderGlobalSettingsKey`), Swift Testing (`@Suite`/`@Test`/`#expect`), strict-layered SPM packages (Domain / Features / App).

**Spec:** `docs/superpowers/specs/2026-06-09-playlist-continuous-playback-design.md`

---

## Architecture Decisions (review these first)

1. **Advance = reload-in-place (not navigation push).** `ReaderViewModel` gains `advance(to:autoPlay:)`. The Reader view stays mounted; the engine and cursor observer (registered once on the shared `PlaybackController`) persist across the reload. This keeps the entire advance mechanism inside the Reader package — no `App`/`Library` navigation changes for advancing, better Back-stack behavior (Back still lands on the playlist), and a smoother transition. **Risk to verify (Task 4 + Task 13):** the cursor observer registered via `controller.observeCursor` in `startObservingCursor()` must remain valid after `releaseEngine()` + reload, because the `PlaybackController` instance is unchanged. If it does not, advance must re-register; manual device verification covers this.

2. **Open-side plumbing = additive `PlaylistReaderRoute`.** Non-playlist opens stay on the existing `ScoreItem` navigation value, untouched. Only opening a score *from a playlist* uses a new `PlaylistReaderRoute { scoreItem, playlistID }` nav value with its own destination, plus a dedicated `onOpenInPlaylist` closure. The Reader re-derives the live ordered queue from `repository.playlists` + `repository.scoreItems` each time it needs "next," so mid-session deletions / reorders are handled.

3. **Continuation value = single global sticky enum** stored under one `@AppStorage` key, surfaced in the inspector (playlist context only) and Settings (always). Default `.playThrough`.

4. **Known limitation (accepted):** `playlistID` is not persisted in the nav snapshot, so after an app relaunch a restored Reader loses playlist context until reopened from the playlist. Noted in spec's out-of-scope spirit; do not add persistence for it.

---

## File Structure

**Domain (new / modified):**
- Create `Packages/Domain/Sources/Domain/Models/PlaylistContinuationMode.swift` — the 3-state enum.
- Create `Packages/Domain/Sources/Domain/Presentation/PlaylistPlaybackProgression.swift` — pure advance decision.
- Modify `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift` — add `playlistContinuationMode` key.
- Test `Packages/Domain/Tests/DomainTests/PlaylistPlaybackProgressionTests.swift`.

**Reader (new / modified):**
- Modify `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift` — `onReachedEnd` callback.
- Modify `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — `playlistID`, `isInPlaylist`, `advance(to:autoPlay:)`, `handlePlaybackReachedEnd()`, queue derivation, `preferencesStore` → `var`, wiring.
- Modify `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` — `playlistID` init param.
- Create `Packages/Features/Reader/Sources/Reader/PlaylistContinuationStorage.swift` — reads the global enum from `UserDefaults`.
- Create `Packages/Features/Reader/Sources/Reader/Views/PlaylistContinuationPicker.swift` — segmented picker.
- Modify `Packages/Features/Reader/Sources/Reader/Screens/PlaybackInspectorScreen.swift` — continuation row + `isInPlaylist`.
- Modify `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift` — pass `isInPlaylist`.
- Modify `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`.
- Test `Packages/Features/Reader/Tests/ReaderTests/ReaderAdvanceTests.swift`.

**Library (new / modified):**
- Create `Packages/Features/Library/Sources/Library/Navigation/PlaylistReaderRoute.swift`.
- Modify `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift` — `onOpenInPlaylist` + `playlistReaderDestination` + new destination.
- Modify `Packages/Features/Library/Sources/Library/Screens/LibraryRootDestinations.swift` — thread `onOpenInPlaylist`.
- Modify `Packages/Features/Library/Sources/Library/Screens/PlaylistDetailScreen.swift` — use `onOpenInPlaylist`.

**App (modified):**
- Modify `App/AppShellView.swift` — `detailPlaylistID` state, `makeReader(...)` helper, route wiring, clear-on-non-playlist.

**Settings (modified):**
- Modify `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift` — continuation control + caption.
- Modify `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`.

**Build/test commands** (from memory — `swift test` is broken by the SwiftLint macOS plugin requirement):
- Package build: `cd Packages/Features/Reader && xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
- Package test: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation` (likewise `-scheme Domain`)
- App build: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`

---

## Phase A — Domain (pure logic; shared with Android)

### Task 1: `PlaylistContinuationMode` enum + global key

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/PlaylistContinuationMode.swift`
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift` (append a key to `ReaderGlobalSettingsKey`)
- Test: `Packages/Domain/Tests/DomainTests/PlaylistContinuationModeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/PlaylistContinuationModeTests.swift`:

```swift
import Testing
@testable import Domain

@Suite("PlaylistContinuationMode")
struct PlaylistContinuationModeTests {
    @Test("raw values are stable for @AppStorage persistence")
    func rawValues() {
        #expect(PlaylistContinuationMode.off.rawValue == "off")
        #expect(PlaylistContinuationMode.playThrough.rawValue == "playThrough")
        #expect(PlaylistContinuationMode.loopPlaylist.rawValue == "loopPlaylist")
    }

    @Test("round-trips through raw value")
    func roundTrip() {
        for mode in PlaylistContinuationMode.allCases {
            #expect(PlaylistContinuationMode(rawValue: mode.rawValue) == mode)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/PlaylistContinuationModeTests`
Expected: FAIL — "cannot find 'PlaylistContinuationMode' in scope".

- [ ] **Step 3: Create the enum**

Create `Packages/Domain/Sources/Domain/Models/PlaylistContinuationMode.swift`:

```swift
/// What happens when a score finishes while it was opened as part of a playlist, **and** no per-score repeat is active
/// (per-score `RepeatMode` always takes priority — see `PlaylistPlaybackProgression`). Stored as a single global,
/// sticky `@AppStorage` value under `ReaderGlobalSettingsKey.playlistContinuationMode`; defaults to `.playThrough`.
public enum PlaylistContinuationMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Stop after the current score.
    case off
    /// Advance through the playlist, then stop after the last score. The default.
    case playThrough
    /// Advance through the playlist; after the last score, wrap to the first and keep going.
    case loopPlaylist
}
```

- [ ] **Step 4: Add the global key**

In `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`, inside `enum ReaderGlobalSettingsKey`, add after `showSeekBarEnabled`:

```swift
    /// `PlaylistContinuationMode.rawValue` (String). Global, sticky. Governs whether finishing a score that was opened
    /// from a playlist advances to the next score. Defaults to `PlaylistContinuationMode.playThrough` at each
    /// `@AppStorage` site. Has no effect when the Reader was opened standalone or when a per-score repeat is active.
    public static let playlistContinuationMode = "readerPlaylistContinuationMode"
```

- [ ] **Step 5: Run test to verify it passes**

Run: same command as Step 2.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/PlaylistContinuationMode.swift Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift Packages/Domain/Tests/DomainTests/PlaylistContinuationModeTests.swift
git commit -m "feat(domain): add PlaylistContinuationMode + global settings key"
```

---

### Task 2: `PlaylistPlaybackProgression.nextAction` (pure decision)

**Files:**
- Create: `Packages/Domain/Sources/Domain/Presentation/PlaylistPlaybackProgression.swift`
- Test: `Packages/Domain/Tests/DomainTests/PlaylistPlaybackProgressionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/PlaylistPlaybackProgressionTests.swift`:

```swift
import Testing
@testable import Domain

@Suite("PlaylistPlaybackProgression.nextAction")
struct PlaylistPlaybackProgressionTests {
    typealias P = PlaylistPlaybackProgression

    @Test("repeat active always stops, regardless of continuation")
    func repeatWins() {
        for mode in PlaylistContinuationMode.allCases {
            #expect(P.nextAction(currentIndex: 0, count: 3, repeatMode: .loopAll, continuation: mode) == .stop)
            #expect(P.nextAction(currentIndex: 0, count: 3, repeatMode: .abLoop, continuation: mode) == .stop)
        }
    }

    @Test("continuation off stops")
    func continuationOff() {
        #expect(P.nextAction(currentIndex: 0, count: 3, repeatMode: .off, continuation: .off) == .stop)
    }

    @Test("playThrough advances in the middle, stops at the last")
    func playThrough() {
        #expect(P.nextAction(currentIndex: 0, count: 3, repeatMode: .off, continuation: .playThrough) == .advance(toIndex: 1))
        #expect(P.nextAction(currentIndex: 1, count: 3, repeatMode: .off, continuation: .playThrough) == .advance(toIndex: 2))
        #expect(P.nextAction(currentIndex: 2, count: 3, repeatMode: .off, continuation: .playThrough) == .stop)
    }

    @Test("loopPlaylist advances in the middle, wraps to 0 at the last")
    func loopPlaylist() {
        #expect(P.nextAction(currentIndex: 1, count: 3, repeatMode: .off, continuation: .loopPlaylist) == .advance(toIndex: 2))
        #expect(P.nextAction(currentIndex: 2, count: 3, repeatMode: .off, continuation: .loopPlaylist) == .advance(toIndex: 0))
    }

    @Test("single-item playlist: playThrough stops, loopPlaylist repeats that item")
    func singleItem() {
        #expect(P.nextAction(currentIndex: 0, count: 1, repeatMode: .off, continuation: .playThrough) == .stop)
        #expect(P.nextAction(currentIndex: 0, count: 1, repeatMode: .off, continuation: .loopPlaylist) == .advance(toIndex: 0))
    }

    @Test("empty or out-of-range stops")
    func degenerate() {
        #expect(P.nextAction(currentIndex: 0, count: 0, repeatMode: .off, continuation: .playThrough) == .stop)
        #expect(P.nextAction(currentIndex: -1, count: 3, repeatMode: .off, continuation: .playThrough) == .stop)
        #expect(P.nextAction(currentIndex: 5, count: 3, repeatMode: .off, continuation: .loopPlaylist) == .stop)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/PlaylistPlaybackProgressionTests`
Expected: FAIL — "cannot find 'PlaylistPlaybackProgression' in scope".

- [ ] **Step 3: Implement the pure function**

Create `Packages/Domain/Sources/Domain/Presentation/PlaylistPlaybackProgression.swift`:

```swift
/// Pure decision for "what to do when a score finishes," given where we are in a playlist, the per-score repeat mode,
/// and the global continuation mode. Shared by the iOS `ReaderViewModel` and the Android reader so both platforms
/// traverse playlists identically.
///
/// Priority ladder (no two-axis truth table): per-score `RepeatMode` is primary — when it is anything other than
/// `.off` the result is always `.stop` (in practice the audio engine loops and never reports end-of-score, so this is
/// belt-and-suspenders). Only when `repeatMode == .off` does `continuation` decide.
public enum PlaylistPlaybackProgression {
    public enum Advance: Hashable, Sendable {
        /// Stop playback at the end of the current score.
        case stop
        /// Reload and auto-play the score at this index in the live ordered playlist.
        case advance(toIndex: Int)
    }

    /// - Parameters:
    ///   - currentIndex: index of the finishing score within the live ordered playlist.
    ///   - count: number of live scores in the playlist.
    ///   - repeatMode: the score's per-score repeat state.
    ///   - continuation: the global playlist-continuation setting.
    public static func nextAction(
        currentIndex: Int,
        count: Int,
        repeatMode: RepeatMode,
        continuation: PlaylistContinuationMode,
    ) -> Advance {
        guard repeatMode == .off else { return .stop }
        guard continuation != .off else { return .stop }
        guard count > 0, currentIndex >= 0, currentIndex < count else { return .stop }

        let next = currentIndex + 1
        if next < count { return .advance(toIndex: next) }
        // At the last score.
        switch continuation {
        case .loopPlaylist: return .advance(toIndex: 0)
        case .playThrough, .off: return .stop
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2.
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Presentation/PlaylistPlaybackProgression.swift Packages/Domain/Tests/DomainTests/PlaylistPlaybackProgressionTests.swift
git commit -m "feat(domain): add PlaylistPlaybackProgression.nextAction"
```

---

## Phase B — Reader advance engine

### Task 3: `ReaderPlaybackSession.onReachedEnd` callback

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift`

This is thin glue (the end-of-score signal already exists). It is verified by Task 4's integration test (`handlePlaybackReachedEnd`) and Task 13's device run, so no standalone unit test here.

- [ ] **Step 1: Add the callback property**

In `ReaderPlaybackSession`, in the "Callbacks" block (after `var onReadyForLoopForward: () async -> Void = {}`), add:

```swift
    /// Fired exactly when the engine reports end-of-score (`cursor == nil` while playing). The owner decides whether to
    /// advance to the next playlist score. Not fired on manual pause/stop — only natural end.
    var onReachedEnd: () async -> Void = {}
```

- [ ] **Step 2: Fire it on natural end**

In `startObservingCursor()`, change the end-of-score branch:

```swift
            if value == nil, isPlaying {
                setPlaying(false)
            }
```

to:

```swift
            if value == nil, isPlaying {
                setPlaying(false)
                Task { [weak self] in await self?.onReachedEnd() }
            }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd Packages/Features/Reader && xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED (look for `Compiling ReaderPlaybackSession.swift`).

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift
git commit -m "feat(reader): add ReaderPlaybackSession.onReachedEnd end-of-score callback"
```

---

### Task 4: `ReaderViewModel` playlist context + advance-in-place

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Create: `Packages/Features/Reader/Sources/Reader/PlaylistContinuationStorage.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderAdvanceTests.swift`

- [ ] **Step 1: Add the global-storage reader helper**

Create `Packages/Features/Reader/Sources/Reader/PlaylistContinuationStorage.swift`:

```swift
import Domain
import Foundation

/// Reads the global, sticky `PlaylistContinuationMode` from `UserDefaults` for imperative (non-`@AppStorage`) code such
/// as `ReaderViewModel`. Mirrors how `A4ReferenceModel` reads its global default. The inspector and Settings write this
/// same key through `@AppStorage(ReaderGlobalSettingsKey.playlistContinuationMode)`.
enum PlaylistContinuationStorage {
    static func current(_ defaults: UserDefaults = .standard) -> PlaylistContinuationMode {
        defaults.string(forKey: ReaderGlobalSettingsKey.playlistContinuationMode)
            .flatMap(PlaylistContinuationMode.init(rawValue:)) ?? .playThrough
    }
}
```

- [ ] **Step 2: Write the failing test**

Create `Packages/Features/Reader/Tests/ReaderTests/ReaderAdvanceTests.swift`:

```swift
import Domain
import Testing
@testable import Reader

@MainActor
@Suite("ReaderViewModel playlist advance")
struct ReaderAdvanceTests {
    /// Two distinct score items + a playlist linking them, all live, on a mutable fake repository.
    private func makeRepo() -> (PreviewFakeRepository, ScoreItem, ScoreItem, Playlist) {
        let a = ScoreItem(
            title: "A", composer: "", instrumentationSummary: "", localFileName: "a.mscx",
            contentHash: "a", sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        let b = ScoreItem(
            title: "B", composer: "", instrumentationSummary: "", localFileName: "b.mscx",
            contentHash: "b", sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 2), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        let playlist = Playlist(
            name: "PL", orderedScoreItemIDs: [a.id, b.id], createdAt: Date(timeIntervalSince1970: 0),
        )
        let repo = PreviewFakeRepository()
        repo.scoreItems = [a, b]
        repo.playlists = [playlist]
        return (repo, a, b, playlist)
    }

    private func makeVM(repo: PreviewFakeRepository, item: ScoreItem, playlistID: PlaylistID?) -> ReaderViewModel {
        ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: PreviewFakeGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playlistID: playlistID,
        )
    }

    @Test("advance(to:) retargets the view model to the new score")
    func advanceRetargets() async {
        let (repo, a, b, pl) = makeRepo()
        let vm = makeVM(repo: repo, item: a, playlistID: pl.id)
        await vm.load()
        #expect(vm.scoreItem.id == a.id)
        await vm.advance(to: b, autoPlay: false)
        #expect(vm.scoreItem.id == b.id)
    }

    @Test("reaching end with playThrough advances A -> B")
    func reachEndAdvances() async {
        let (repo, a, b, pl) = makeRepo()
        UserDefaults.standard.set(PlaylistContinuationMode.playThrough.rawValue, forKey: ReaderGlobalSettingsKey.playlistContinuationMode)
        let vm = makeVM(repo: repo, item: a, playlistID: pl.id)
        await vm.load()
        await vm.handlePlaybackReachedEnd()
        #expect(vm.scoreItem.id == b.id)
    }

    @Test("reaching end at the last score with playThrough stays put")
    func reachEndStopsAtLast() async {
        let (repo, _, b, pl) = makeRepo()
        UserDefaults.standard.set(PlaylistContinuationMode.playThrough.rawValue, forKey: ReaderGlobalSettingsKey.playlistContinuationMode)
        let vm = makeVM(repo: repo, item: b, playlistID: pl.id)
        await vm.load()
        await vm.handlePlaybackReachedEnd()
        #expect(vm.scoreItem.id == b.id)
    }

    @Test("standalone (no playlistID) never advances")
    func standaloneNeverAdvances() async {
        let (repo, a, _, _) = makeRepo()
        UserDefaults.standard.set(PlaylistContinuationMode.playThrough.rawValue, forKey: ReaderGlobalSettingsKey.playlistContinuationMode)
        let vm = makeVM(repo: repo, item: a, playlistID: nil)
        await vm.load()
        await vm.handlePlaybackReachedEnd()
        #expect(vm.scoreItem.id == a.id)
        #expect(vm.isInPlaylist == false)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:ReaderTests/ReaderAdvanceTests`
Expected: FAIL — `ReaderViewModel.init` has no `playlistID:` parameter; `advance`, `handlePlaybackReachedEnd`, `isInPlaylist` undefined.

- [ ] **Step 4: Make `preferencesStore` mutable and store `playlistID`**

In `ReaderViewModel.swift`, change:

```swift
    @ObservationIgnored private let preferencesStore: ReaderPreferencesStore
```

to:

```swift
    @ObservationIgnored private var preferencesStore: ReaderPreferencesStore
```

Add a stored property next to `scoreItem`:

```swift
    /// The playlist this Reader is traversing, or `nil` when opened standalone. Drives the inspector's continuation
    /// control and end-of-score auto-advance. The live ordered queue is re-derived from the repository on demand.
    @ObservationIgnored private let playlistID: PlaylistID?
```

- [ ] **Step 5: Add `playlistID` to the initializer**

Add the parameter to `init` (after `museScoreGeneralProvider:`):

```swift
        playlistID: PlaylistID? = nil,
```

and assign it at the top of the body (next to `self.scoreItem = scoreItem`):

```swift
        self.playlistID = playlistID
```

Then, at the end of `init`, after `wirePiPSession()`, the new end-of-score wiring is added in Step 7.

- [ ] **Step 6: Add the public/computed surface**

Add near `var preferences: ReaderPreferences { ... }`:

```swift
    /// Whether the inspector should show the playlist-continuation control. True only when opened from a playlist.
    var isInPlaylist: Bool { playlistID != nil }
```

- [ ] **Step 7: Wire the end-of-score callback**

In `wirePlaybackSession()`, after the `onReadyForLoopForward` assignment, add:

```swift
        playbackSession.onReachedEnd = { [weak self] in
            await self?.handlePlaybackReachedEnd()
        }
```

- [ ] **Step 8: Implement queue derivation, end handling, and advance**

Add to the `// MARK: - Private` section (the `handlePlaybackReachedEnd` is `internal`, not `private`, so the test can call it):

```swift
    /// The live, ordered `ScoreItemID`s of the playlist being traversed, filtered to items that still exist.
    /// Empty when standalone or when the playlist no longer exists.
    private func currentPlaylistQueue() -> [ScoreItemID] {
        guard let playlistID,
              let playlist = repository.playlists.first(where: { $0.id == playlistID })
        else { return [] }
        let liveIDs = Set(repository.scoreItems.map(\.id))
        return PlaylistPresentation.orderedLiveIDs(playlist, liveIDs: liveIDs)
    }

    /// Called when the engine reports end-of-score. Decides via `PlaylistPlaybackProgression` whether to advance to the
    /// next live playlist score and auto-play it. No-op when standalone, when the current score is no longer in the
    /// live queue, or when the decision is `.stop`.
    func handlePlaybackReachedEnd() async {
        let queue = currentPlaylistQueue()
        guard let currentIndex = queue.firstIndex(of: scoreItem.id) else { return }
        let action = PlaylistPlaybackProgression.nextAction(
            currentIndex: currentIndex,
            count: queue.count,
            repeatMode: repeatModel.mode,
            continuation: PlaylistContinuationStorage.current(),
        )
        switch action {
        case .stop:
            return
        case let .advance(toIndex):
            guard let nextItem = repository.scoreItems.first(where: { $0.id == queue[toIndex] }) else { return }
            await advance(to: nextItem, autoPlay: true)
        }
    }

    /// Retarget this Reader to a different score *in place*: tear down the engine, swap the score item and its
    /// preferences store, reload the score + preferences (which re-syncs every sub-model), then optionally auto-play.
    /// The view and the shared `PlaybackController` (and its cursor observer) stay mounted across the swap.
    func advance(to newItem: ScoreItem, autoPlay: Bool) async {
        await playbackSession.releaseEngine()
        scoreItem = newItem
        preferencesStore = ReaderPreferencesStore(
            scoreItemID: newItem.id,
            defaultStaffSize: defaultStaffSize,
            repository: repository,
        )
        hasUpdatedLastOpened = false
        await load()
        await playbackSession.prepareForPlayback()
        // Re-seed the global metronome state into the freshly-loaded engine (mirrors ReaderRootScreen's `.task`).
        let metronomeEnabled = UserDefaults.standard.bool(forKey: ReaderGlobalSettingsKey.metronomeEnabled)
        await tempoModel.setMetronomeEnabled(metronomeEnabled)
        if autoPlay {
            await playbackSession.togglePlayback()
        }
    }
```

> Note: `preferencesStore` is read via `preferencesProvider = { [weak self] in self?.preferencesStore.preferences }` (set once in `wirePlaybackSession`). Because the closure reads `self.preferencesStore` each call, reassigning the property is picked up automatically — no re-wiring needed.

- [ ] **Step 9: Run test to verify it passes**

Run: same command as Step 3.
Expected: PASS (4 tests).

- [ ] **Step 10: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift Packages/Features/Reader/Sources/Reader/PlaylistContinuationStorage.swift Packages/Features/Reader/Tests/ReaderTests/ReaderAdvanceTests.swift
git commit -m "feat(reader): advance-in-place to next playlist score on end-of-score"
```

---

## Phase C — Reader inspector UI

### Task 5: `PlaylistContinuationPicker` view

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Views/PlaylistContinuationPicker.swift`

This is a pure SwiftUI control modeled on `RepeatModePicker`. Verified by the inspector preview in Task 6; no unit test.

- [ ] **Step 1: Create the picker**

Create `Packages/Features/Reader/Sources/Reader/Views/PlaylistContinuationPicker.swift`:

```swift
import Domain
import SwiftUI

/// Three-state segmented control for the global playlist-continuation setting. Shown only in playlist context.
struct PlaylistContinuationPicker: View {
    @Binding var selection: PlaylistContinuationMode

    var body: some View {
        Picker("", selection: $selection) {
            Text("reader.inspector.continuation.off", bundle: .module)
                .tag(PlaylistContinuationMode.off)
            Text("reader.inspector.continuation.playThrough", bundle: .module)
                .tag(PlaylistContinuationMode.playThrough)
            Text("reader.inspector.continuation.loopPlaylist", bundle: .module)
                .tag(PlaylistContinuationMode.loopPlaylist)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

#if DEBUG
#Preview {
    PlaylistContinuationPicker(selection: .constant(.playThrough))
}
#endif
```

- [ ] **Step 2: Build to verify it compiles** (localization keys are added in Task 12; the build still compiles — `Text("key")` with a missing catalog entry renders the key literally, it is not a compile error)

Run: `cd Packages/Features/Reader && xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Views/PlaylistContinuationPicker.swift
git commit -m "feat(reader): add PlaylistContinuationPicker segmented control"
```

---

### Task 6: Continuation row in the playback inspector

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/PlaybackInspectorScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift`

- [ ] **Step 1: Add `isInPlaylist` + continuation storage to the inspector**

In `PlaybackInspectorScreen.swift`, add a stored property after `let playbackCursor: ScoreCursor?`:

```swift
    /// True when the Reader was opened from a playlist — gates whether the continuation row is shown.
    let isInPlaylist: Bool
```

and an `@AppStorage` next to the existing `isMetronomeEnabled`:

```swift
    @AppStorage(ReaderGlobalSettingsKey.playlistContinuationMode)
    private var continuationMode: PlaylistContinuationMode = .playThrough
```

- [ ] **Step 2: Render the gated row**

In `body`, inside the first `CollapsibleSection`, immediately after the repeat-mode `HStack { ... RepeatModePicker(...) }` block and before `masterVolumeRow`, add:

```swift
                if isInPlaylist {
                    continuationRow
                }
```

Then add the `continuationRow` builder after `masterVolumeRow` (before `tempoRow`):

```swift
    @ViewBuilder
    private var continuationRow: some View {
        // The continuation control is subordinate to per-score repeat: when repeat is looping this score it is
        // disabled, with a caption explaining why playback won't advance.
        let repeatActive = repeatModel.mode != .off
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "music.note.list")
                    .foregroundStyle(Color.accentColor)
                Text("reader.inspector.continuation", bundle: .module)
                Spacer()
                PlaylistContinuationPicker(selection: $continuationMode)
                    .disabled(repeatActive)
            }
            if repeatActive {
                Text("reader.inspector.continuation.repeatActive", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
```

- [ ] **Step 3: Pass `isInPlaylist` from the inspector's call site**

In `ReaderTopOverlay.swift`, in `inspectorButtons(score:)`, update the `PlaybackInspectorScreen(...)` initializer to add the new argument after `playbackCursor:`:

```swift
                    playbackCursor: viewModel.playbackSession.playbackCursor,
                    isInPlaylist: viewModel.isInPlaylist,
```

- [ ] **Step 4: Update the inspector's own `#Preview`**

In `PlaybackInspectorScreen.swift`'s `#Preview`, add `isInPlaylist: true,` to the `PlaybackInspectorScreen(...)` call (after `playbackCursor:`). This lets the preview exercise the new row.

- [ ] **Step 5: Render the preview to verify**

Use `mcp__xcode__RenderPreview` on `PlaybackInspectorScreen.swift`'s `#Preview` and `Read` the PNG. Confirm:
- the "Playlist" row with a 3-segment control appears (because `isInPlaylist: true`),
- when the preview's `repeatModel.mode` is `.off`, the control is enabled and no caption shows.

(If the plugin trust prompt blocks the render, build the Reader scheme instead and rely on Task 13's device check.)

- [ ] **Step 6: Build the Reader package**

Run: `cd Packages/Features/Reader && xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PlaybackInspectorScreen.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift
git commit -m "feat(reader): playlist-continuation row in the playback inspector"
```

---

## Phase D — Open-side plumbing (carry `playlistID` into the Reader)

### Task 7: `PlaylistReaderRoute` navigation value

**Files:**
- Create: `Packages/Features/Library/Sources/Library/Navigation/PlaylistReaderRoute.swift`

- [ ] **Step 1: Create the route type**

Create `Packages/Features/Library/Sources/Library/Navigation/PlaylistReaderRoute.swift`:

```swift
import Domain

/// Navigation value for opening a score **from a playlist**, carrying the originating playlist so the Reader can
/// traverse it (continuous playback). Non-playlist opens keep using the plain `ScoreItem` navigation value, so this is
/// purely additive — it does not change any existing open path.
public struct PlaylistReaderRoute: Hashable, Sendable {
    public let scoreItem: ScoreItem
    public let playlistID: PlaylistID

    public init(scoreItem: ScoreItem, playlistID: PlaylistID) {
        self.scoreItem = scoreItem
        self.playlistID = playlistID
    }
}
```

- [ ] **Step 2: Build the Library package**

Run: `cd Packages/Features/Library && xcodebuild build -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Navigation/PlaylistReaderRoute.swift
git commit -m "feat(library): add PlaylistReaderRoute navigation value"
```

---

### Task 8: Thread `onOpenInPlaylist` + the playlist Reader destination

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/PlaylistDetailScreen.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootDestinations.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift`

- [ ] **Step 1: `PlaylistDetailScreen` calls a playlist-aware open**

In `PlaylistDetailScreen.swift`, replace the property:

```swift
    let onOpen: (ScoreItem) -> Void
```

with:

```swift
    /// Opens a score while recording that it came from this playlist, so the Reader can traverse the playlist.
    let onOpenInPlaylist: (ScoreItem, PlaylistID) -> Void
```

and in `body`, change the `PlaylistDetailView(...)` argument:

```swift
            onOpen: onOpen,
```

to:

```swift
            onOpen: { item in onOpenInPlaylist(item, playlist.id) },
```

- [ ] **Step 2: `libraryRootDestination` threads the new closure**

In `LibraryRootDestinations.swift`, add a parameter to the function signature (after `onAddToPlaylist:`):

```swift
    onOpenInPlaylist: @escaping (ScoreItem, PlaylistID) -> Void,
```

and in the `.playlistDetail` case, change the `PlaylistDetailScreen(...)` construction:

```swift
            PlaylistDetailScreen(
                playlist: playlist,
                library: viewModel,
                onOpen: onOpenScore,
                onPlaylistDeleted: { /* same comment as tag */ },
            )
```

to:

```swift
            PlaylistDetailScreen(
                playlist: playlist,
                library: viewModel,
                onOpenInPlaylist: onOpenInPlaylist,
                onPlaylistDeleted: { /* same comment as tag */ },
            )
```

- [ ] **Step 3: `LibraryRootScreen` gains the closure + the playlist destination**

In `LibraryRootScreen.swift`, add two stored properties after `private let readerDestination: (ScoreItem) -> ReaderContent`:

```swift
    private let playlistReaderDestination: (PlaylistReaderRoute) -> ReaderContent
    private let onOpenInPlaylist: (ScoreItem, PlaylistID) -> Void
```

Add the matching `init` parameters (after `readerDestination:`):

```swift
        @ViewBuilder playlistReaderDestination: @escaping (PlaylistReaderRoute) -> ReaderContent,
        onOpenInPlaylist: @escaping (ScoreItem, PlaylistID) -> Void,
```

and assign them in `init` (after `self.readerDestination = readerDestination`):

```swift
        self.playlistReaderDestination = playlistReaderDestination
        self.onOpenInPlaylist = onOpenInPlaylist
```

Pass the closure into the destination router — change:

```swift
                .navigationDestination(for: LibraryRoute.self) { route in
                    libraryRootDestination(
                        for: route,
                        viewModel: viewModel,
                        onOpenScore: onOpenScore,
                        onEditTags: { editTagsTarget = $0 },
                        onAddToPlaylist: { addToPlaylistTarget = $0 },
                    )
                }
```

to:

```swift
                .navigationDestination(for: LibraryRoute.self) { route in
                    libraryRootDestination(
                        for: route,
                        viewModel: viewModel,
                        onOpenScore: onOpenScore,
                        onEditTags: { editTagsTarget = $0 },
                        onAddToPlaylist: { addToPlaylistTarget = $0 },
                        onOpenInPlaylist: onOpenInPlaylist,
                    )
                }
```

Add the new destination directly after the existing `.navigationDestination(for: ScoreItem.self)`:

```swift
                .navigationDestination(for: PlaylistReaderRoute.self) { route in
                    playlistReaderDestination(route)
                }
```

- [ ] **Step 4: Build the Library package**

Run: `cd Packages/Features/Library && xcodebuild build -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: FAIL to link only at the App layer later; the Library package itself should BUILD SUCCEEDED. If the package has previews/call sites of `LibraryRootScreen` inside the package, update them to pass the two new arguments (search `LibraryRootScreen(` within `Packages/Features/Library`). Expected after fixes: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/PlaylistDetailScreen.swift Packages/Features/Library/Sources/Library/Screens/LibraryRootDestinations.swift Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift
git commit -m "feat(library): thread onOpenInPlaylist + PlaylistReaderRoute destination"
```

---

### Task 9: `ReaderRootScreen` accepts `playlistID`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

- [ ] **Step 1: Add the init parameter and forward it**

In `ReaderRootScreen.init`, add a parameter after `museScoreGeneralProvider:`:

```swift
        playlistID: PlaylistID? = nil,
```

and forward it into the `ReaderViewModel(...)` construction (add after `museScoreGeneralProvider: museScoreGeneralProvider,`):

```swift
                playlistID: playlistID,
```

- [ ] **Step 2: Build the Reader package**

Run: `cd Packages/Features/Reader && xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift
git commit -m "feat(reader): ReaderRootScreen accepts optional playlistID"
```

---

### Task 10: `AppShellView` wiring (both layout modes)

**Files:**
- Modify: `App/AppShellView.swift`

- [ ] **Step 1: Add `detailPlaylistID` state (iPad)**

In `ReadyShell`, add after `@State private var detailScoreItem: ScoreItem?`:

```swift
    @State private var detailPlaylistID: PlaylistID?
```

- [ ] **Step 2: Add a `makeReader` helper to remove duplication**

Add this method to `ReadyShell` (e.g. just above `private var detail`):

```swift
    @ViewBuilder
    private func makeReader(
        item: ScoreItem,
        playlistID: PlaylistID?,
        onBack: (() -> Void)? = nil,
        hidesBackButton: Bool = false,
    ) -> some View {
        ReaderRootScreen(
            scoreItem: item,
            repository: repository,
            gateway: gateway,
            shareService: shareService,
            metadataReader: metadataReader,
            scoresDirectory: scoresDirectory,
            playbackController: bootstrap.playbackController,
            museScoreGeneralProvider: bootstrap.museScoreGeneralProvider,
            onBack: onBack,
            hidesBackButton: hidesBackButton,
            playlistID: playlistID,
        )
    }
```

- [ ] **Step 3: Compact (iPhone) — wire the playlist destination + `onOpenInPlaylist`**

Replace the compact `LibraryRootScreen(...)` (the `else` branch in `body`) with:

```swift
                LibraryRootScreen(
                    viewModel: libraryVM,
                    path: $compactPath,
                    onOpenScore: { compactPath.append($0) },
                    readerDestination: { item in
                        makeReader(item: item, playlistID: nil)
                    },
                    playlistReaderDestination: { route in
                        makeReader(item: route.scoreItem, playlistID: route.playlistID)
                    },
                    onOpenInPlaylist: { item, playlistID in
                        compactPath.append(PlaylistReaderRoute(scoreItem: item, playlistID: playlistID))
                    },
                    licenseContent: { LicenseListView() },
                    leadingToolbarItem: { settingsButton },
                )
```

- [ ] **Step 4: iPad sidebar — wire `onOpenInPlaylist` + clear `detailPlaylistID` for plain opens**

Replace the `sidebar` computed property with:

```swift
    private var sidebar: some View {
        LibraryRootScreen(
            viewModel: libraryVM,
            path: $sidebarPath,
            onOpenScore: { item in
                detailPlaylistID = nil
                detailScoreItem = item
                columnVisibility = .detailOnly
            },
            readerDestination: { item in
                makeReader(item: item, playlistID: nil)
            },
            playlistReaderDestination: { route in
                makeReader(item: route.scoreItem, playlistID: route.playlistID)
            },
            onOpenInPlaylist: { item, playlistID in
                detailPlaylistID = playlistID
                detailScoreItem = item
                columnVisibility = .detailOnly
            },
            licenseContent: { LicenseListView() },
            leadingToolbarItem: { settingsButton },
        )
    }
```

- [ ] **Step 5: iPad detail — pass `detailPlaylistID` via `makeReader`**

Replace the `detail` computed property's `ReaderRootScreen(...)` with the helper:

```swift
    @ViewBuilder
    private var detail: some View {
        if let item = detailScoreItem {
            makeReader(
                item: item,
                playlistID: detailPlaylistID,
                onBack: { columnVisibility = .doubleColumn },
                hidesBackButton: columnVisibility == .doubleColumn,
            )
            // Force a fresh view identity per score so ReaderRootScreen's @State (viewModel seeded from scoreItem in
            // init) is rebuilt when the user opens a different score from the iPad sidebar.
            .id(item.id)
        } else {
            emptyDetail
        }
    }
```

- [ ] **Step 6: Clear `detailPlaylistID` on programmatic / import opens (iPad)**

These paths open a single score outside any playlist, so the iPad's playlist context must be cleared. In `.onChange(of: libraryVM.pendingScoreToOpen?.id)`, in the `horizontalSizeClass == .regular` branch, add `detailPlaylistID = nil` before `detailScoreItem = item`:

```swift
            if horizontalSizeClass == .regular {
                sidebarPath = NavigationPath()
                detailPlaylistID = nil
                detailScoreItem = item
                columnVisibility = .detailOnly
            } else {
```

In `runDrain`, the `.openReader` case, the `horizontalSizeClass == .regular` branch, add `detailPlaylistID = nil` before `detailScoreItem = item`:

```swift
            if horizontalSizeClass == .regular {
                sidebarPath = NavigationPath()
                if let playlistUnderneath {
                    sidebarPath.append(playlistUnderneath)
                }
                detailPlaylistID = nil
                detailScoreItem = item
                columnVisibility = .detailOnly
            } else {
```

In `resetNavigationForIncomingURL`, the `horizontalSizeClass == .regular` branch, add `detailPlaylistID = nil` next to `detailScoreItem = nil`:

```swift
        if horizontalSizeClass == .regular {
            sidebarPath = NavigationPath()
            detailPlaylistID = nil
            detailScoreItem = nil
            columnVisibility = .doubleColumn
        } else {
```

- [ ] **Step 7: Build the app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED. (If `LibraryRootScreen`'s generic `ReaderContent` fails to infer because the two destination closures return slightly different opaque types, wrap each in `AnyView` at the call sites in `makeReader`-using closures — but since both go through `makeReader`, they share one concrete type and inference should hold.)

- [ ] **Step 8: Commit**

```bash
git add App/AppShellView.swift
git commit -m "feat(app): pass playlistID into Reader for playlist-originated opens"
```

---

## Phase E — Settings + localization

### Task 11: Settings continuation control + precedence caption

**Files:**
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift`

- [ ] **Step 1: Add the `@AppStorage` value**

In `SettingsSheet`, add next to the other Reader `@AppStorage` properties:

```swift
    @AppStorage(ReaderGlobalSettingsKey.playlistContinuationMode)
    private var continuationMode: PlaylistContinuationMode = .playThrough
```

- [ ] **Step 2: Add the control + caption to `readerSection`**

In `readerSection`, add this row after the `seekBarToggle` (and before `readerLayoutRow`):

```swift
            Picker(selection: $continuationMode) {
                Text("settings.reader.continuation.off", bundle: .module)
                    .tag(PlaylistContinuationMode.off)
                Text("settings.reader.continuation.playThrough", bundle: .module)
                    .tag(PlaylistContinuationMode.playThrough)
                Text("settings.reader.continuation.loopPlaylist", bundle: .module)
                    .tag(PlaylistContinuationMode.loopPlaylist)
            } label: {
                Label {
                    Text("settings.reader.continuation", bundle: .module)
                } icon: {
                    Image(systemName: "music.note.list")
                }
            }
```

If the `Section` has no `footer:`, add one to the `Section` that holds `readerSection`'s rows; otherwise append this text to the existing footer. The caption:

```swift
            Text("settings.reader.continuation.footer", bundle: .module)
```

(If `readerSection` is a bare `Section { ... }` with no footer closure, convert it to `Section { ... } footer: { Text("settings.reader.continuation.footer", bundle: .module) }`.)

- [ ] **Step 3: Build the Settings package**

Run: `cd Packages/Features/Settings && xcodebuild build -scheme Settings -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift
git commit -m "feat(settings): global playlist-continuation control with precedence caption"
```

---

### Task 12: Localization strings (en + ja)

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`
- Modify: `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`

Copy below is **proposed** (spec marked wording as TBD); adjust freely. Brand stays lowercase `folino` (not referenced here).

- [ ] **Step 1: Add Reader keys**

Add these entries to `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` (en value + ja translation each):

| key | en | ja |
| --- | --- | --- |
| `reader.inspector.continuation` | Playlist | プレイリスト |
| `reader.inspector.continuation.off` | Off | オフ |
| `reader.inspector.continuation.playThrough` | Continuous | 連続再生 |
| `reader.inspector.continuation.loopPlaylist` | Repeat All | 全曲リピート |
| `reader.inspector.continuation.repeatActive` | Looping this score — playback won't move to the next. | この楽譜をリピート中のため、次の楽譜へは進みません。 |

Easiest path: build the Reader scheme so Xcode's string-catalog extraction registers the new `Text("…")` keys as untranslated, then open `Localizable.xcstrings` in Xcode and fill en (state `translated`) + ja. Per memory `feedback_xcstrings_refactor`, the tool does not auto-remove keys — do not delete unrelated entries.

- [ ] **Step 2: Add Settings keys**

Add to `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`:

| key | en | ja |
| --- | --- | --- |
| `settings.reader.continuation` | Continuous Playlist Playback | プレイリストの連続再生 |
| `settings.reader.continuation.off` | Off | オフ |
| `settings.reader.continuation.playThrough` | Continuous | 連続再生 |
| `settings.reader.continuation.loopPlaylist` | Repeat All | 全曲リピート |
| `settings.reader.continuation.footer` | When you set a per-score repeat (single or A–B), it takes priority and playback won't advance to the next score. | 楽譜ごとに「1曲」または「A–B」リピートを設定している場合は、そちらが優先され、次の楽譜へは進みません。 |

- [ ] **Step 3: Build app to confirm strings resolve**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings
git commit -m "i18n: continuous-playback strings for inspector and settings (en/ja)"
```

---

## Phase F — Verification

### Task 13: Full test run + device verification

**Files:** none (verification only).

- [ ] **Step 1: Run the Domain test suite**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/PlaylistPlaybackProgressionTests -only-testing:DomainTests/PlaylistContinuationModeTests`
Expected: PASS.

- [ ] **Step 2: Run the Reader advance suite**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:ReaderTests/ReaderAdvanceTests`
Expected: PASS.

- [ ] **Step 3: Build the full app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Hand off device verification to the user**

Per project convention (`feedback_no_simulator_launch`), do NOT auto-launch. Ask the user to clean-build and run, then verify:
  1. **Default continuous:** open a multi-score playlist, play the first score to its end → it advances to and auto-plays the next; at the last score it stops.
  2. **Repeat wins:** in the inspector set repeat to "1曲" (loopAll) → the "Playlist" control greys out with the caption; the score loops and never advances.
  3. **Off:** set "プレイリスト = オフ" → score stops at its end, no advance.
  4. **Repeat All:** set "全曲リピート" → after the last score it wraps to the first.
  5. **Standalone:** open the same score NOT from a playlist (All Scores) → no "Playlist" row in the inspector; playback stops at the end.
  6. **iPad + iPhone** both: advance shows the next score; **Back** lands on the playlist.
  7. **Cursor-observer-after-reload risk (Decision 1):** after an auto-advance, confirm the new score's cursor highlights/auto-scrolls during playback and that reaching ITS end advances again (proves the observer survived `releaseEngine()` + reload). If it does not, re-register the observer at the end of `advance(to:autoPlay:)` by calling `playbackSession.startObservingCursor()` — but only after confirming `observeCursor` replaces rather than appends its stored closure.

- [ ] **Step 5: Final no-op commit / branch ready** — nothing to commit; report results to the user.

---

## Self-Review Notes

- **Spec coverage:** ladder (Tasks 2, 6) · default Continuous (Task 1 default + Task 4 storage) · global sticky in two surfaces (Tasks 6, 11) · inspector playlist-only (Task 6 `isInPlaylist`) · Settings caption (Task 11) · provenance plumbing (Tasks 7–10) · advance + per-score preferences applied on advance (Task 4 reloads via `load()`) · deleted-score skip (Task 4 `currentPlaylistQueue` via `orderedLiveIDs`) · single-item & wrap edge cases (Task 2 tests) · Android parity (Domain logic in Tasks 1–2 is shared; Android UI is a separate follow-up, out of this plan's scope).
- **Android:** Tasks 1–2 land the shared logic in Domain; the Android reader's continuation UI + JNI wiring is a separate follow-up plan, consistent with the repo's "logic shared, UI per-platform" rule.
