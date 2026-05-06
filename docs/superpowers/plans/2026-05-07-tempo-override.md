# Tempo Override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a master tempo control + metronome on/off to the Reader's MixerView, persist tempo override per score, and apply rate changes to the live playback engine immediately.

**Architecture:** A single `Optional<Double>` on `ReaderPreferences` carries the per-score override (`nil` = native tempo, normalized so saving `1.0` yields `nil`). A new `setRate(_:)` API on `swift-sheet-music`'s `PlaybackEngine` writes to `AVAudioSequencer.rate` (and re-applies after sequencer rebuilds). Metronome on/off is global via `@AppStorage`.

**Tech Stack:** Swift 6.3, SwiftUI, AVFoundation (via swift-sheet-music), Swift Testing, SwiftPM.

**Companion repo:** `git@github.com:jiyimeta/swift-sheet-music.git` at `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music` (Folino pins this by `revision:` SHA).

**Spec:** `docs/superpowers/specs/2026-05-07-tempo-override-design.md`

---

## Task 1: Add `setRate(_:)` to `PlaybackEngine` in swift-sheet-music

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicAudio/PlaybackEngine.swift`

This is a separate repo; commit + push there before bumping the Folino revision.

- [ ] **Step 1: Add `pendingRate` storage near the other sequencer-related fields**

In `PlaybackEngine.swift`, find the `sequencerScore` property (currently around line 58) and add directly after it:

```swift
    /// Most recent rate set by the host. Stored separately from the
    /// sequencer so the value survives `buildSequencer` rebuilds —
    /// every fresh `AVAudioSequencer` starts at 1.0 and we re-apply
    /// this value once it's built.
    private var pendingRate: Float = 1.0
```

- [ ] **Step 2: Add the public `setRate` method**

In the same file, find the existing `setMetronomeEnabled` / `setMetronomeVolume` block (around line 94) and add a new public method directly above the `// MARK: Internal accessors for PlaybackEngine+Mixer` comment (or anywhere in the file's public API section — match neighbouring style):

```swift
    /// Scale playback speed. `1.0` is the score's native tempo;
    /// `0.5`–`2.0` is the host's typical slider range, but no
    /// clamping is applied here — the caller is expected to enforce
    /// musically reasonable bounds. The new value persists across
    /// sequencer rebuilds (e.g. `play(from:in:)` on a fresh score).
    public func setRate(_ rate: Float) {
        pendingRate = rate
        sequencer?.rate = rate
    }
```

- [ ] **Step 3: Re-apply the rate at the end of `buildSequencer`**

In `buildSequencer(for:)` (currently around line 443), find the existing tail:

```swift
        metronome.attach(to: sequencer)
        sequencer.prepareToPlay()
        self.sequencer = sequencer
    }
```

Replace with:

```swift
        metronome.attach(to: sequencer)
        sequencer.rate = pendingRate
        sequencer.prepareToPlay()
        self.sequencer = sequencer
    }
```

- [ ] **Step 4: Build swift-sheet-music to verify nothing broke**

Run from `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`:

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music && swift build
```

Expected: `Build complete!` (warnings OK, errors fail).

- [ ] **Step 5: Commit and capture the new SHA**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music
git add Sources/SheetMusicAudio/PlaybackEngine.swift
git commit -m "$(cat <<'EOF'
feat(audio): expose setRate on PlaybackEngine

Hosts can now scale playback speed by writing AVAudioSequencer.rate
through a small public API. The value is remembered across sequencer
rebuilds (play-from-cursor, prepare-on-different-score) so the host
override stays sticky.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
NEW_SHEET_MUSIC_SHA=$(git rev-parse HEAD)
echo "$NEW_SHEET_MUSIC_SHA"
```

Record the SHA — it will be pasted into Folino's `Package.swift` files in Task 2.

---

## Task 2: Bump swift-sheet-music revision in Folino

**Files:**
- Modify: `Packages/Domain/Package.swift`
- Modify: `Packages/Infrastructure/Package.swift`
- Modify: `Packages/Features/Reader/Package.swift`
- Modify: `project.yml`

The current pinned revision is `d16665385bc38c3d3efc11752a8079a84a5e91d6`. Replace it with the SHA from Task 1.

- [ ] **Step 1: Update all four pinned references**

In each of the three `Package.swift` files and `project.yml`, replace the existing 40-char SHA with the new one. Quote-style varies between Package.swift (quoted) and project.yml (bare); preserve the existing form.

Example diff for `Packages/Domain/Package.swift`:

```swift
        .package(
            url: "git@github.com:jiyimeta/swift-sheet-music.git",
            revision: "<NEW_SHA>"
        ),
```

Example diff for `project.yml`:

```yaml
  swift-sheet-music:
    url: "git@github.com:jiyimeta/swift-sheet-music.git"
    revision: <NEW_SHA>
```

- [ ] **Step 2: Regenerate the Xcode project**

```bash
xcodegen generate
```

Expected: `Loaded project: Folino` ... `Created project at Folino.xcodeproj`.

- [ ] **Step 3: Resolve packages on each Swift package, confirming the new revision pulls cleanly**

```bash
cd Packages/Domain && swift package resolve && cd ../..
cd Packages/Infrastructure && swift package resolve && cd ../..
cd Packages/Features/Reader && swift package resolve && cd ../../..
```

Expected: each command prints `Computing version for ... swift-sheet-music` referencing the new SHA, then exits 0.

- [ ] **Step 4: Commit**

```bash
git add Packages/Domain/Package.swift Packages/Infrastructure/Package.swift \
        Packages/Features/Reader/Package.swift project.yml \
        Packages/*/Package.resolved Packages/Features/*/Package.resolved
git commit -m "$(cat <<'EOF'
chore(deps): bump swift-sheet-music to expose PlaybackEngine.setRate

Pulls the new public setRate API used by the Reader's tempo override.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(If `Package.resolved` files do not exist for some packages, the `git add` glob is harmless — git ignores absent paths.)

---

## Task 3: Add `tempoMultiplier` to `ReaderPreferences`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift`, inside the `@Suite struct ReaderPreferencesTests {}` body (before the closing brace):

```swift
    @Test func tempoMultiplierDefaultsToNil() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: []
        )
        #expect(prefs.tempoMultiplier == nil)
    }

    @Test func tempoMultiplierIsClampedToHalfThroughDouble() {
        let tooSlow = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 0.1
        )
        #expect(tooSlow.tempoMultiplier == 0.5)

        let tooFast = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 5.0
        )
        #expect(tooFast.tempoMultiplier == 2.0)

        let inRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 0.75
        )
        #expect(inRange.tempoMultiplier == 0.75)
    }

    @Test func tempoMultiplierNilRoundTripsThroughCodable() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: []
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.tempoMultiplier == nil)
    }

    @Test func tempoMultiplierRoundTripsThroughCodable() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 1.25
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.tempoMultiplier == 1.25)
    }

    @Test func legacyJSONWithoutTempoMultiplierKeyDecodesAsNil() throws {
        // Ensures additive-only schema change: rows persisted before
        // tempoMultiplier landed must still load. We synthesize the
        // "legacy" shape by encoding the current struct and stripping
        // the new key, so we don't have to hand-write IDs whose
        // encoded form is implementation-defined.
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: []
        )
        let encoded = try JSONEncoder().encode(prefs)
        var dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        dict.removeValue(forKey: "tempoMultiplier")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: stripped)
        #expect(decoded.tempoMultiplier == nil)
        #expect(decoded.staffSize == 14)
    }
```

- [ ] **Step 2: Run the tests to confirm they fail (compile error or wrong default)**

```bash
cd Packages/Domain && swift test --filter ReaderPreferencesTests
```

Expected: compile error referencing `tempoMultiplier:` argument label that doesn't exist.

- [ ] **Step 3: Add the property**

Edit `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`. The current file is small — replace its `public struct ReaderPreferences` body so it reads exactly:

```swift
public struct ReaderPreferences: Hashable, Sendable, Codable, Identifiable {
    public static let minStaffSize: CGFloat = 8
    public static let maxStaffSize: CGFloat = 28
    public static let minTempoMultiplier: Double = 0.5
    public static let maxTempoMultiplier: Double = 2.0

    public let id: ReaderPreferencesID
    public let scoreItemID: ScoreItemID
    public var staffSize: CGFloat
    public var hiddenStaves: Set<StaffAddress>
    /// User-chosen GM program (0…127) per staff that overrides whatever the
    /// score declares. Absent entries fall back to the score's instrument
    /// channel program. Bank stays at 0 — the picker only swaps melodic
    /// programs (matches `swift-sheet-music`'s `ProgramMenu`).
    public var staffProgramOverrides: [StaffAddress: Int]
    /// Per-score playback rate override. `nil` means "no override" — the
    /// engine plays at the score's native tempo. Set values are clamped to
    /// `[minTempoMultiplier, maxTempoMultiplier]`. The Reader's view model
    /// normalizes a saved value of exactly 1.0 back to `nil` so the
    /// override doesn't outlive the user's intent.
    public var tempoMultiplier: Double?

    public init(
        id: ReaderPreferencesID = ReaderPreferencesID(),
        scoreItemID: ScoreItemID,
        staffSize: CGFloat,
        hiddenStaves: Set<StaffAddress>,
        staffProgramOverrides: [StaffAddress: Int] = [:],
        tempoMultiplier: Double? = nil
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.staffSize = min(max(staffSize, Self.minStaffSize), Self.maxStaffSize)
        self.hiddenStaves = hiddenStaves
        self.staffProgramOverrides = staffProgramOverrides.mapValues { min(max($0, 0), 127) }
        self.tempoMultiplier = tempoMultiplier.map {
            min(max($0, Self.minTempoMultiplier), Self.maxTempoMultiplier)
        }
    }
}
```

- [ ] **Step 4: Run the tests; confirm they pass**

```bash
cd Packages/Domain && swift test --filter ReaderPreferencesTests
```

Expected: all `ReaderPreferencesTests` cases pass, including the four new ones.

- [ ] **Step 5: Run the full Domain test suite**

```bash
cd Packages/Domain && swift test
```

Expected: all tests pass (no other site references `ReaderPreferences.init` positionally — `staffProgramOverrides` and `tempoMultiplier` are both defaulted, so existing call sites compile unchanged).

- [ ] **Step 6: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift \
        Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift
git commit -m "$(cat <<'EOF'
feat(domain): add tempoMultiplier override to ReaderPreferences

Optional Double clamped to [0.5, 2.0]. nil means no override (native
tempo). Existing persisted rows decode with nil for free — no
migration needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire `setTempoMultiplier` in `LivePlaybackController`

**Files:**
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`

The protocol method exists but is an empty stub. We forward to `engine.setRate` and also seed the rate during `load(score:preferences:)`.

- [ ] **Step 1: Replace the stub**

In `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`, find:

```swift
    // Stubs — engine doesn't expose these yet; keep the protocol whole.
    public func setLoopRange(_: ABRepeatRange?) {}
    public func setTempoMultiplier(_: Double) {}
```

Replace with:

```swift
    // Stub — engine doesn't expose loop ranges yet; keep the protocol whole.
    public func setLoopRange(_: ABRepeatRange?) {}

    public func setTempoMultiplier(_ value: Double) {
        engine.setRate(Float(value))
    }
```

- [ ] **Step 2: Apply the seeded rate inside `load`**

In the same file, find the body of `load(score:preferences:)` after the per-staff loop:

```swift
        for state in preferences.perStaff {
            engine.setVolume(
                forChannel: .staff(state.staffIndex), to: Float(state.volume)
            )
            engine.setMuted(
                forChannel: .staff(state.staffIndex), to: state.isMuted
            )
            engine.setSoloed(
                forChannel: .staff(state.staffIndex), to: state.isSolo
            )
        }
    }
```

Replace with:

```swift
        for state in preferences.perStaff {
            engine.setVolume(
                forChannel: .staff(state.staffIndex), to: Float(state.volume)
            )
            engine.setMuted(
                forChannel: .staff(state.staffIndex), to: state.isMuted
            )
            engine.setSoloed(
                forChannel: .staff(state.staffIndex), to: state.isSolo
            )
        }
        engine.setRate(Float(preferences.tempoMultiplier))
    }
```

- [ ] **Step 3: Build the Infrastructure package**

```bash
cd Packages/Infrastructure && swift build
```

Expected: build succeeds (Infrastructure has no test target that exercises this path; the engine call lands on a real `AVAudioEngine` that we don't spin up in unit tests).

- [ ] **Step 4: Commit**

```bash
git add Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift
git commit -m "$(cat <<'EOF'
feat(audio): forward tempo multiplier to swift-sheet-music PlaybackEngine

Replaces the empty setTempoMultiplier stub with engine.setRate, and
applies the seeded preferences.tempoMultiplier during load so the
engine has the correct rate before the first play() call.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Make `FakePlaybackController` record tempo + metronome calls

**Files:**
- Modify: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift`

The fake currently has no-op `setMetronomeEnabled` and `setTempoMultiplier`. The Reader tests need to assert on these — record the call history.

- [ ] **Step 1: Add recording state and replace the stubs**

Find these lines in `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift`:

```swift
    private(set) var recordedSetCursorCalls: [ScoreCursor] = []
```

Add directly after them:

```swift
    private(set) var tempoMultiplierCalls: [Double] = []
    private(set) var metronomeEnabledCalls: [Bool] = []
```

Then find:

```swift
    func setLoopRange(_: ABRepeatRange?) {}
    func setMetronomeEnabled(_: Bool) {}
    func setTempoMultiplier(_: Double) {}
```

Replace with:

```swift
    func setLoopRange(_: ABRepeatRange?) {}
    func setMetronomeEnabled(_ enabled: Bool) {
        metronomeEnabledCalls.append(enabled)
    }
    func setTempoMultiplier(_ value: Double) {
        tempoMultiplierCalls.append(value)
    }
```

- [ ] **Step 2: Run an existing Reader test as a smoke check**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelTests
```

Expected: existing suites still pass — confirms the fake's new properties haven't broken its protocol conformance.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift
git commit -m "$(cat <<'EOF'
test(reader): record tempo + metronome calls on FakePlaybackController

Lets ReaderViewModelTempoTests assert on the call history.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add tempo + metronome ops to `ReaderViewModel` (TDD)

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTempoTests.swift` (new file)

- [ ] **Step 1: Write the failing tests**

Create `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTempoTests.swift`:

```swift
import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@Suite @MainActor
struct ReaderViewModelTempoTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    private static func makeVM(
        controller: FakePlaybackController = FakePlaybackController(),
        repo: FakeScoreLibraryRepository = FakeScoreLibraryRepository()
    ) -> (ReaderViewModel, FakePlaybackController, FakeScoreLibraryRepository) {
        let item = Self.makeItem()
        repo.scoreItems = [item]
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        return (vm, controller, repo)
    }

    @Test func effectiveTempoMultiplierDefaultsToOne() {
        let (vm, _, _) = Self.makeVM()
        #expect(vm.effectiveTempoMultiplier == 1.0)
    }

    @Test func setTempoMultiplierForwardsToControllerWithoutPersisting() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()
        let savedBefore = repo.savedReaderPreferences.count

        vm.setTempoMultiplier(0.75)

        #expect(controller.tempoMultiplierCalls == [0.75])
        #expect(repo.savedReaderPreferences.count == savedBefore)
        #expect(vm.effectiveTempoMultiplier == 1.0) // not yet committed
    }

    @Test func commitTempoMultiplierPersistsAndForwards() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        await vm.commitTempoMultiplier(0.75)

        #expect(controller.tempoMultiplierCalls.last == 0.75)
        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == 0.75)
        #expect(vm.effectiveTempoMultiplier == 0.75)
    }

    @Test func commitTempoMultiplierNormalizesOneToNil() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        await vm.commitTempoMultiplier(1.0)

        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == nil)
        #expect(controller.tempoMultiplierCalls.last == 1.0)
        #expect(vm.effectiveTempoMultiplier == 1.0)
    }

    @Test func commitTempoMultiplierClampsOutOfRangeValues() async {
        let (vm, _, repo) = Self.makeVM()
        await vm.load()

        await vm.commitTempoMultiplier(3.0)

        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == 2.0)
        #expect(vm.effectiveTempoMultiplier == 2.0)
    }

    @Test func resetTempoMultiplierClearsOverrideAndForwardsOne() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()
        await vm.commitTempoMultiplier(1.5)

        await vm.resetTempoMultiplier()

        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == nil)
        #expect(controller.tempoMultiplierCalls.last == 1.0)
        #expect(vm.effectiveTempoMultiplier == 1.0)
    }

    @Test func setMetronomeEnabledForwardsWithoutPersisting() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()
        let savedBefore = repo.savedReaderPreferences.count

        await vm.setMetronomeEnabled(true)
        await vm.setMetronomeEnabled(false)

        #expect(controller.metronomeEnabledCalls == [true, false])
        #expect(repo.savedReaderPreferences.count == savedBefore)
    }
}
```

- [ ] **Step 2: Run the new tests; confirm they fail to compile (methods don't exist)**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelTempoTests
```

Expected: compile error referring to missing `effectiveTempoMultiplier`, `setTempoMultiplier`, `commitTempoMultiplier`, `resetTempoMultiplier`, `setMetronomeEnabled` on `ReaderViewModel`.

- [ ] **Step 3: Add the new public API to `ReaderViewModel`**

Open `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`. Add this block right above the `// MARK: - Private` line near the bottom of the file:

```swift
    // MARK: - Tempo & metronome

    /// Effective playback rate multiplier — falls back to 1.0 when no
    /// override is set. The MixerView slider uses this to seed its
    /// local edit state.
    public var effectiveTempoMultiplier: Double { preferences.tempoMultiplier ?? 1.0 }

    /// While the user is dragging the slider: forward the new rate to
    /// the engine immediately for audible feedback. Does NOT persist —
    /// the View calls `commitTempoMultiplier` on slider release.
    public func setTempoMultiplier(_ value: Double) {
        Task { await playbackController?.setTempoMultiplier(value) }
    }

    /// On slider release: persist the override (normalizing 1.0 → nil)
    /// and forward to the engine.
    public func commitTempoMultiplier(_ value: Double) async {
        let normalized: Double? = value == 1.0 ? nil : value
        await mutatePreferences { $0.tempoMultiplier = normalized }
        let effective = preferences.tempoMultiplier ?? 1.0
        await playbackController?.setTempoMultiplier(effective)
    }

    /// Reset to native tempo. Clears the saved override and forwards 1.0.
    public func resetTempoMultiplier() async {
        await mutatePreferences { $0.tempoMultiplier = nil }
        await playbackController?.setTempoMultiplier(1.0)
    }

    /// Forward metronome on/off to the engine. Persistence is owned by
    /// the View layer via @AppStorage("readerMetronomeEnabled") so it
    /// survives across scores.
    public func setMetronomeEnabled(_ enabled: Bool) async {
        await playbackController?.setMetronomeEnabled(enabled)
    }
```

- [ ] **Step 4: Update `mutatePreferences` to carry `tempoMultiplier` through**

In the same file, find the existing `mutatePreferences` helper (currently around line 401):

```swift
    private func mutatePreferences(_ apply: (inout ReaderPreferences) -> Void) async {
        var copy = preferences
        apply(&copy)
        // Re-seat through the initializer so clamping rules in
        // `ReaderPreferences.init` always run.
        let normalized = ReaderPreferences(
            id: copy.id,
            scoreItemID: copy.scoreItemID,
            staffSize: copy.staffSize,
            hiddenStaves: copy.hiddenStaves,
            staffProgramOverrides: copy.staffProgramOverrides
        )
        preferences = normalized
        try? await repository.saveReaderPreferences(normalized)
    }
```

Replace with:

```swift
    private func mutatePreferences(_ apply: (inout ReaderPreferences) -> Void) async {
        var copy = preferences
        apply(&copy)
        // Re-seat through the initializer so clamping rules in
        // `ReaderPreferences.init` always run.
        let normalized = ReaderPreferences(
            id: copy.id,
            scoreItemID: copy.scoreItemID,
            staffSize: copy.staffSize,
            hiddenStaves: copy.hiddenStaves,
            staffProgramOverrides: copy.staffProgramOverrides,
            tempoMultiplier: copy.tempoMultiplier
        )
        preferences = normalized
        try? await repository.saveReaderPreferences(normalized)
    }
```

- [ ] **Step 5: Run the new tests; confirm they pass**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelTempoTests
```

Expected: all 7 cases pass.

- [ ] **Step 6: Run the full Reader test suite to confirm no regressions**

```bash
cd Packages/Features/Reader && swift test
```

Expected: all suites pass (existing program-override tests still work because `tempoMultiplier` is defaulted in `ReaderPreferences.init` and `mutatePreferences` now carries the field through).

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTempoTests.swift
git commit -m "$(cat <<'EOF'
feat(reader): add tempo & metronome control surface to ReaderViewModel

setTempoMultiplier (live-only) drives the engine without persisting,
commitTempoMultiplier saves the override (normalizing 1.0 → nil) and
forwards. resetTempoMultiplier clears the override.
setMetronomeEnabled forwards to the engine; persistence stays in the
View via @AppStorage.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Add the master tempo + metronome row to `MixerView`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/MixerView.swift`

- [ ] **Step 1: Add `@AppStorage` and slider edit state, then prepend a master section**

Replace the contents of `Packages/Features/Reader/Sources/Reader/MixerView.swift`:

```swift
import SheetMusicAudio
import SheetMusicCore
import SwiftUI

struct MixerView: View {
    @Bindable var viewModel: ReaderViewModel
    let score: Score

    @AppStorage("readerMetronomeEnabled") private var isMetronomeEnabled: Bool = false
    /// Slider's local edit value. Syncs from `viewModel.effectiveTempoMultiplier`
    /// when the user is not dragging — keeps the UI consistent after a reset
    /// from outside the slider (e.g. the % label tap).
    @State private var sliderValue: Double = 1.0
    @State private var isEditingTempo: Bool = false

    var body: some View {
        List {
            masterRow
            ForEach(score.parts.indices, id: \.self) { partIndex in
                let part = score.parts[partIndex]
                Section {
                    ForEach(part.staves.indices, id: \.self) { staffIndex in
                        staffRow(address: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex))
                    }
                } header: {
                    Text(part.instrument.longName ?? part.trackName ?? "-")
                        .font(.headline)
                        .padding(.bottom, -8)
                }
                .headerProminence(.increased)
                .padding(.bottom, -8)
            }
        }
        .listStyle(.plain)
        .buttonStyle(.plain)
        .padding(.top, 16)
        .environment(\.defaultMinListRowHeight, 28)
        .task(id: viewModel.effectiveTempoMultiplier) {
            // Pull the persisted value into the slider whenever the model
            // changes from outside the gesture (initial load, % tap reset).
            if !isEditingTempo {
                sliderValue = viewModel.effectiveTempoMultiplier
            }
        }
        .task {
            await viewModel.setMetronomeEnabled(isMetronomeEnabled)
        }
    }

    @ViewBuilder
    private var masterRow: some View {
        Section {
            HStack(spacing: 8) {
                Button {
                    isMetronomeEnabled.toggle()
                    Task { await viewModel.setMetronomeEnabled(isMetronomeEnabled) }
                } label: {
                    Image(systemName: isMetronomeEnabled ? "metronome.fill" : "metronome")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                        .padding(.horizontal, 4)
                }

                Button {
                    Task { await viewModel.resetTempoMultiplier() }
                } label: {
                    Text("\(Int((sliderValue * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(minWidth: 44, alignment: .trailing)
                }

                Slider(
                    value: $sliderValue,
                    in: 0.5 ... 2.0,
                    onEditingChanged: { editing in
                        isEditingTempo = editing
                        if editing {
                            viewModel.setTempoMultiplier(sliderValue)
                        } else {
                            Task { await viewModel.commitTempoMultiplier(sliderValue) }
                        }
                    }
                )
                .onChange(of: sliderValue) { _, newValue in
                    if isEditingTempo {
                        viewModel.setTempoMultiplier(newValue)
                    }
                }
                .padding(.vertical, -8)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func staffRow(address: StaffAddress) -> some View {
        let volumeBinding = Binding<Double>(
            get: { viewModel.volume(for: address) },
            set: { viewModel.setVolume($0, for: address) }
        )
        let isMuted = viewModel.mutedStaves.contains(address)
        let isSolo = viewModel.soloStaves.contains(address)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Slider(value: volumeBinding, in: 0 ... 1)
                    .disabled(isMuted || !viewModel.soloStaves.isEmpty && !isSolo)
                    .padding(.vertical, -8)

                Button {
                    viewModel.toggleStaffSolo(address: address)
                } label: {
                    Image(systemName: isSolo ? "s.circle.fill" : "s.circle")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                        .padding(.horizontal, 4)
                }

                Button {
                    viewModel.toggleStaffMute(address: address)
                } label: {
                    Image(systemName: isMuted ? "m.circle.fill" : "m.circle")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                        .padding(.horizontal, 4)
                }
                visibilityButton(address: address)
            }
            programPicker(address: address)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func programPicker(address: StaffAddress) -> some View {
        let program = viewModel.effectiveProgram(for: address)
        let hasOverride = viewModel.hasProgramOverride(for: address)
        HStack(spacing: 6) {
            Image(systemName: "music.note.list")
                .foregroundStyle(.secondary)
            Menu {
                if hasOverride {
                    Button {
                        Task { await viewModel.clearStaffProgramOverride(for: address) }
                    } label: {
                        Label("Reset to default", systemImage: "arrow.uturn.backward")
                    }
                    Divider()
                }
                ForEach(GMInstrument.Family.allCases, id: \.self) { family in
                    Section(family.rawValue) {
                        ForEach(family.programs) { instrument in
                            Button {
                                Task {
                                    await viewModel.setStaffProgram(
                                        Int(instrument.program), for: address
                                    )
                                }
                            } label: {
                                Text(instrument.name)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(GMInstrument.instrument(for: UInt8(clamping: program)).name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuIndicator(.hidden)
        }
        .font(.caption)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    func visibilityButton(address: StaffAddress) -> some View {
        let isVisible = !viewModel.preferences.hiddenStaves.contains(address)

        Button {
            Task { await viewModel.toggleStaff(address: address) }
        } label: {
            EyeIcon(isOpen: isVisible, lineWidth: 2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 24)
        }
        .contentShape(.rect)
        .animation(.spring(duration: 0.18), value: isVisible)
    }
}

#Preview {
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0",
                trackName: "Violin",
                instrument: Instrument(
                    id: "violin",
                    channels: [InstrumentChannel(program: 40)] // GM 40 = Violin
                ),
                staves: [Staff()]
            ),
            Part(
                id: "P1",
                trackName: "Piano",
                instrument: Instrument(
                    id: "piano",
                    channels: [InstrumentChannel(program: 0)] // GM 0 = Acoustic Grand Piano
                ),
                staves: [Staff(), Staff()]
            ),
        ],
        metaTags: [:]
    )
    let repo = PreviewFakeRepository()
    let vm = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: repo,
        gateway: PreviewFakeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp")
    )
    Text("Contents")
        .task { await vm.load() }
        .sheet(isPresented: .constant(true)) {
            MixerView(viewModel: vm, score: score)
                .presentationDetents([.medium, .large])
        }
}
```

- [ ] **Step 2: Build the Reader package**

```bash
cd Packages/Features/Reader && swift build
```

Expected: build succeeds.

- [ ] **Step 3: Build the full app for the simulator**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/MixerView.swift
git commit -m "$(cat <<'EOF'
feat(reader): tempo + metronome master row in MixerView

Top section of the mixer now hosts a metronome on/off button
(persisted globally via @AppStorage), a percentage label that taps
to reset, and a continuous tempo slider. Drag forwards live to the
engine; release commits the override to ReaderPreferences.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Verify the preview and the simulator build

**Files:** none modified — verification only.

- [ ] **Step 1: Render the MixerView preview**

Use Xcode's preview MCP to render the existing `#Preview` in `Packages/Features/Reader/Sources/Reader/MixerView.swift`. Save the PNG and `Read` it.

Confirm visually:
- Master row shows `metronome` SF Symbol on the left (outline form, not filled, since the default is OFF).
- A `100%` label sits between the icon and the slider.
- Slider is at the centre position (1.0 within `0.5...2.0`).

- [ ] **Step 2: Tap the metronome icon in the preview path**

(Optional, fast check via preview only.) If the preview doesn't drive interactions, skip and confirm visually only — interaction is covered by tests in Task 6.

- [ ] **Step 3: Run the full app build one more time as a smoke test**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`. (Repeat now after the preview render so the worktree is in known-good state for handoff.)

- [ ] **Step 4: Final test sweep**

```bash
cd Packages/Domain && swift test
cd ../Infrastructure && swift test
cd ../Features/Reader && swift test
```

Expected: each package's full suite passes.

- [ ] **Step 5: No commit needed for verification**

If any of the verification steps surfaced an issue, return to the relevant task and fix in place; otherwise the worktree is ready to merge.
