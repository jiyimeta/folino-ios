# Transpose — Plan 2: Folino iOS wiring

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) tracking.

**Goal:** Wire the semitone transpose feature (−7…+7) into the Folino iOS Reader: a per-score `TransposeModel` drives both the displayed engraving (via `Score.transposed`) and live audio (via a new `PlaybackController.setTranspose`), exposed as a mirrored row in both inspectors.

**Architecture:** A single `TransposeModel` (owned by `ReaderViewModel`, modeled on `TempoModel` / `MasterVolumeModel`) is the source of truth. Display reads it in `ReaderRootScreen.content` and inserts `.transposed(bySemitones:)` into the existing `Score → Score` transform pipeline. Audio forwards it to the engine through a new `PlaybackController.setTranspose(semitones:)` (the ssm engine already implements live coarse-tuning on its melodic unit). Persistence is per-score via a new `ReaderPreferences.transposeSemitones`.

**Tech Stack:** Swift 6, Domain (protocols), Infrastructure (concrete `PlaybackController` adapter over `SheetMusicAudio.PlaybackEngine`), Reader feature (SwiftUI), Swift Testing. ssm is pinned at `cfc6d06` (has `Score.transposed`, `PlaybackEngine.setTranspose`).

**Scope:** Folino iOS only. Android = Plan 3. Branch `worktree-transpose` at `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/transpose` (abbrev `$F`). Verify Reader feature package builds via its own scheme (app build can false-SUCCEED by skipping the package — see project memory).

---

## Task 1: Domain protocol + fake

**Files:**
- Modify: `$F/Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift`
- Modify: `$F/Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift`

- [ ] **Step 1:** Add to the `PlaybackController` protocol, next to `setTempoMultiplier` / `setMasterVolume`:
```swift
    /// Set the live whole-score transpose in semitones (−7…+7). The engine shifts pitched channels by global coarse
    /// tuning, leaving drums at concert pitch; no score reload. Out-of-range values are clamped by the adapter.
    func setTranspose(semitones: Int) async
```

- [ ] **Step 2:** In `FakePlaybackController`, add a recorded property mirroring how it records `setMasterVolume` etc. (read the fake first to match its style):
```swift
    private(set) var transposeSemitones = 0
    func setTranspose(semitones: Int) async { transposeSemitones = semitones }
```

- [ ] **Step 3:** Build Domain: `cd $F/Packages/Domain && xcodebuild build -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation 2>&1 | tail` → expect a `Compiling` of `PlaybackController.swift` and `** BUILD SUCCEEDED **`. (Per project memory, the Reader fake compiles with its package — covered in later tasks.)

- [ ] **Step 4:** Commit (`git -C $F add <files>`, message `feat(domain): PlaybackController.setTranspose`).

---

## Task 2: Infrastructure adapter

**Files:**
- Modify: the concrete `PlaybackController` adapter in `$F/Packages/Infrastructure/Sources/...` (find it: `grep -rln "PlaybackController" $F/Packages/Infrastructure/Sources` — the class conforming to `PlaybackController`, wrapping `SheetMusicAudio.PlaybackEngine`).

- [ ] **Step 1:** Read the adapter; find how `setMasterVolume` / `setTempoMultiplier` forward to the engine (likely `await engine.setMasterTuning`-style or actor-hop). Add the mirroring method, clamping to ±7:
```swift
    func setTranspose(semitones: Int) async {
        await engine.setTranspose(semitones: max(-7, min(7, semitones)))
    }
```
(Match the adapter's actual engine-access pattern — `engine` may be reached via an actor / stored property; mirror `setMasterVolume`'s exact form. `PlaybackEngine.setTranspose` is synchronous `@MainActor`; bridge the same way the other setters do.)

- [ ] **Step 2:** Build Infrastructure: `cd $F/Packages/Infrastructure && xcodebuild build -scheme Infrastructure -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation 2>&1 | tail` → `** BUILD SUCCEEDED **`.

- [ ] **Step 3:** Commit (`feat(infra): forward setTranspose to the audio engine`).

---

## Task 3: ReaderPreferences field + TransposeModel + VM wiring

**Files:**
- Modify: `ReaderPreferences` (find: `grep -rln "struct ReaderPreferences" $F/Packages/Features/Reader/Sources`).
- Create: `$F/Packages/Features/Reader/Sources/Reader/TransposeModel.swift`
- Modify: `$F/Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `$F/Packages/Features/Reader/Tests/ReaderTests/TransposeModelTests.swift` (create)

- [ ] **Step 1:** Add `transposeSemitones: Int` (default 0) to `ReaderPreferences` (read the struct; mirror an existing `Int`/optional field's declaration + any Codable/init wiring). Per-score persistence is automatic via the existing `ReaderPreferencesStore`.

- [ ] **Step 2:** Read `TempoModel.swift` and `MasterVolumeModel.swift` as templates. Create `TransposeModel` mirroring their shape:
```swift
import Observation
import SheetMusicCore

@MainActor
@Observable
final class TransposeModel {
    private(set) var semitones: Int = 0

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored var controllerProvider: () -> (any PlaybackController)? = { nil }

    func sync(from prefs: ReaderPreferences) { semitones = prefs.transposeSemitones }

    func setSemitones(_ value: Int) async {
        let clamped = max(-7, min(7, value))
        guard clamped != semitones else { return }
        semitones = clamped
        await controllerProvider()?.setTranspose(semitones: clamped)
        await onChange?()
    }

    func reset() async { await setSemitones(0) }
}
```
(Adjust imports / `PlaybackController` visibility to match how `TempoModel` references the controller. If `TempoModel` uses `controllerProvider` returning the session's controller, mirror exactly.)

- [ ] **Step 3:** Wire into `ReaderViewModel`: add `var transposeModel = TransposeModel()`; add `wireTransposeModel()` (mirror `wireTempoModel`) that sets `onChange` → `preferencesStore.mutate { $0.transposeSemitones = self.transposeModel.semitones }` and `controllerProvider` → `self.playbackSession.controller`; call it in `init`; add `transposeModel.sync(from: prefs)` in `loadOrSeedPreferences()`. Also: after transpose changes, the PiP renderer must rebuild — in `onChange`, call `pipSession.armIfReady()` (mirror `wireLayoutModel`'s PiP rebuild).

- [ ] **Step 4 (TDD test):** In `TransposeModelTests` (Swift Testing), verify: clamping to ±7; `setSemitones` forwards to a `FakePlaybackController` (via `controllerProvider`); `onChange` fires; `sync(from:)` reads the pref. Mirror `ReaderViewModelMasterVolumeTests` for harness setup.

- [ ] **Step 5:** Build Reader package + run the test:
`cd $F/Packages/Features/Reader && xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:ReaderTests/TransposeModelTests 2>&1 | tail -20` → tests pass.

- [ ] **Step 6:** Commit (`feat(reader): TransposeModel + per-score persistence`).

---

## Task 4: Display pipeline

**Files:**
- Modify: `$F/Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

- [ ] **Step 1:** In `content`'s `.loaded(score)` case, the current pipeline is:
```swift
let withClefs = score.applying(clefOverrides: viewModel.layoutModel.staffClefOverrides)
let visible = withClefs.filtered(hidingStaves: viewModel.layoutModel.hiddenStaves)
```
Insert the transpose between them (transpose preserves note IDs / ticks, so cursor translation downstream is unaffected):
```swift
let withClefs = score.applying(clefOverrides: viewModel.layoutModel.staffClefOverrides)
let transposed = withClefs.transposed(bySemitones: viewModel.transposeModel.semitones)
let visible = transposed.filtered(hidingStaves: viewModel.layoutModel.hiddenStaves)
```
`viewModel.transposeModel.semitones` is observed, so changing it re-renders. `Score.transposed` is from `SheetMusicCore` (already imported).

- [ ] **Step 2:** Build the Reader package (per memory, verify the package scheme shows `Compiling ReaderRootScreen.swift`):
`cd $F/Packages/Features/Reader && xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation 2>&1 | tail` → SUCCEEDED.

- [ ] **Step 3:** Commit (`feat(reader): apply transpose in the score display pipeline`).

---

## Task 5: Mirrored inspector row

**Files:**
- Create: `$F/Packages/Features/Reader/Sources/Reader/Views/TransposeRow.swift`
- Modify: `$F/Packages/Features/Reader/Sources/Reader/Screens/PlaybackInspectorScreen.swift`
- Modify: `$F/Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift`
- Modify: localization catalog (find the Reader `.xcstrings`; add keys).

- [ ] **Step 1:** Create a shared `TransposeRow` view taking the `TransposeModel`. A ♯♭-style icon + signed readout (`+2` / `−3` / `0`) + a `Stepper` bound `-7...7`; the readout/stepper drive `Task { await transposeModel.setSemitones(...) }`. Model the row's look on `PlaybackInspectorScreen`'s `tempoReadoutLine` stepper (the `Stepper(value:in:step:)` + leading icon + label). Use a localized label key `reader.inspector.transpose` (icon e.g. SF Symbol `arrow.up.arrow.down` or a ♯/♭ glyph; match existing inspector iconography — accent-colored leading image like the other rows). Reset to 0 on a double-tap of the readout (mirror tempo's reset-on-tap).
```swift
import Domain
import SwiftUI
import UtilityUI

struct TransposeRow: View {
    @Bindable var transposeModel: TransposeModel

    var body: some View {
        let binding = Binding<Int>(
            get: { transposeModel.semitones },
            set: { newValue in Task { await transposeModel.setSemitones(newValue) } },
        )
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(Color.accentColor)
            Text("reader.inspector.transpose", bundle: .module)
            Spacer()
            Button {
                Task { await transposeModel.reset() }
            } label: {
                Text(verbatim: transposeModel.semitones > 0
                    ? "+\(transposeModel.semitones)" : "\(transposeModel.semitones)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 32, alignment: .trailing)
            }
            Stepper(value: binding, in: -7 ... 7) { EmptyView() }
                .labelsHidden()
                .fixedSize()
        }
    }
}
```
(`@Bindable` requires the model be `@Observable` — it is. Confirm `TransposeModel` is accessible / same module — it is, all in `Reader`.)

- [ ] **Step 2:** Add `TransposeRow(transposeModel: ...)` to the *General* `CollapsibleSection` of BOTH `PlaybackInspectorScreen` (after `tempoRow`, before repeat/masterVolume) and `VisualInspectorScreen` (after `staffSizeRow`). Both screens need access to the model: thread `let transposeModel: TransposeModel` into each screen's init and pass `viewModel.transposeModel` at both call sites (find where the two inspectors are presented — `ReaderViewModel.isPlaybackInspectorPresented` / `isVisualInspectorPresented` sheets, likely in `ReaderTopOverlay` or `ReaderRootScreen`). Update the `#Preview`s to pass a `TransposeModel()`.

- [ ] **Step 3:** Localization: add `reader.inspector.transpose` (en: "Transpose") to the Reader feature's `.xcstrings` (find it: `find $F/Packages/Features/Reader -name "*.xcstrings"`). Follow the existing `reader.inspector.*` key scheme (project memory: module.feature.thing). Japanese value per the app's existing localization practice.

- [ ] **Step 4:** Build the Reader package → SUCCEEDED. Optionally render a `#Preview` of each inspector via `mcp__xcode__RenderPreview` to eyeball the row (per the user's preview-first workflow).

- [ ] **Step 5:** Commit (`feat(reader): mirror a transpose row in both inspectors`).

---

## Task 6: Picture-in-Picture

**Files:**
- Modify: `$F/Packages/Features/Reader/Sources/Reader/PiP/...` (`PiPLayoutSnapshot` + the frame renderer that builds the PiP score image; and `ReaderViewModel.currentPiPLayoutSnapshot()`).

- [ ] **Step 1:** Add `transposeSemitones: Int` to `PiPLayoutSnapshot` (read it first; mirror `staffSize` / `clefOverrides` fields). Populate it in `ReaderViewModel.currentPiPLayoutSnapshot()` from `transposeModel.semitones`.

- [ ] **Step 2:** In the PiP frame renderer (`ScorePiPFrameRenderer` / wherever the snapshot's clefOverrides + hiddenStaves are applied to build the rendered score), insert `.transposed(bySemitones: snapshot.transposeSemitones)` in the SAME order as `ReaderRootScreen` (after clef overrides, before hidden-staves filter), so PiP matches the main view.

- [ ] **Step 3:** Build the Reader package → SUCCEEDED. (PiP behavior is verified later in the simulator by the user; no unit test.)

- [ ] **Step 4:** Commit (`feat(reader): carry transpose into the PiP renderer`).

---

## Task 7: App build + verification handoff

- [ ] **Step 1:** Regenerate + build the app:
`cd $F && xcodegen generate` then the documented app build (`xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`). Expect SUCCEEDED. (If iPhone 16 sim is absent, use iPhone 17 per project memory.)

- [ ] **Step 2: HANDOFF (no simulator launch by Claude — project convention).** Ask the user to run the Reader and confirm: transpose stepper in BOTH inspectors changes the engraving (notes + key signature, with the chromatic-spelling / global-key behavior) and the playback pitch live; drums unaffected; value persists per-score (reopen the score); PiP overlay matches.

- [ ] **Step 3:** On approval, this branch (`worktree-transpose`) carries spec + Plan 1 + engine-split + Plan 2; finish per `superpowers:finishing-a-development-branch` (merge to Folino main). Then Plan 3 (Android).

---

## Self-review notes

- **Spec coverage** (`2026-06-06-reader-transpose-design.md`): mirrored placement both inspectors (T5); per-score persistence (T3); live audio via `setTranspose` (T1/T2); display transform in pipeline (T4); PiP (T6); drums excluded (handled in ssm `Score.transposed` + engine, already pinned). Range ±7 clamped in model + adapter + stepper.
- **Out of scope:** Android (Plan 3); resulting-key-name readout; the global-key-spelling logic (already in ssm).
- **Verify-by-reading flags:** exact `ReaderPreferences` shape, `TempoModel` controller-access pattern, the concrete Infra adapter's engine bridge, `PiPLayoutSnapshot` fields, and the inspector presentation sites — each implementer reads the real file and mirrors the existing pattern before editing.
