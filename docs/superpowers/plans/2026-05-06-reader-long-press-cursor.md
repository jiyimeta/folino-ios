# Reader long-press cursor seek (vertical mode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user long-press the score in `ReaderView` (vertical layout) to move the playback cursor to the nearest playable event on the staff under the touch — visual immediately, audible if playback is running.

**Architecture:** Long-press lives on the score surface inside `VerticalScoreContainer` (named coord space `"scoreSurface"`), so the gesture's location is already in `LayoutDocument` coordinates — no transform inversion. A new helper `nearestCursor(at:in:)` in the Reader package picks the closest event. `ReaderViewModel.setManualCursor(_:)` writes `playbackCursor` immediately and forwards the cursor to the playback controller. The `Domain.PlaybackController.setCursor(to:)` API switches from `ChordPath` to `ScoreCursor` so rests can be addressed; `LivePlaybackController` becomes a one-liner over `PlaybackEngine.seek(to:)`.

**Tech Stack:** Swift 6.3, SwiftUI (iOS 26+), Swift Testing, `swift-sheet-music` (`SheetMusicCore`, `SheetMusicLayout`, `SheetMusicUI`), `SheetMusicAudio` (Infrastructure only).

**Spec:** `docs/superpowers/specs/2026-05-06-reader-long-press-cursor-design.md`.

**Branch:** Create `feat/reader-long-press-cursor` off `main` before Task 0; commit per task. Open a PR to `main` when Task 8 completes.

## File Structure

| File | Status | Responsibility |
| --- | --- | --- |
| `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift` | Modify | Change `setCursor(to: ChordPath)` → `setCursor(to: ScoreCursor)`. |
| `Packages/Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift` | Modify | Update fake + test to new signature. |
| `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` | Modify | Implement `setCursor` via `engine.seek(to:)`. |
| `Packages/Features/Reader/Sources/Reader/NearestCursor.swift` | Create | Hit-test helper `nearestCursor(at:in:)`. |
| `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` | Modify | Add `setManualCursor(_:)`. |
| `Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift` | Modify | Named coord space + composed long-press gesture + haptic + view-model wiring. |
| `Packages/Features/Reader/Sources/Reader/ReaderView.swift` | Modify | Pass `viewModel` into `VerticalScoreContainer`. |
| `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift` | Modify | New signature + `recordedSetCursorCalls`. |
| `Packages/Features/Reader/Tests/ReaderTests/NearestCursorTests.swift` | Create | Unit tests for the hit-test helper. |
| `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelManualCursorTests.swift` | Create | View-model tests for `setManualCursor`. |

The Domain change ripples into Infrastructure, the in-package fake, and one Domain unit test. Reader-side work is contained in the Reader package.

---

## Task 0: Branch + smoke baseline

**Files:** none new.

- [ ] **Step 1: Cut a feature branch**

```bash
git switch -c feat/reader-long-press-cursor
```

- [ ] **Step 2: Confirm app build still passes**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: `** BUILD SUCCEEDED **`

If the project file is stale, regenerate first: `xcodegen generate`.

- [ ] **Step 3: Confirm Domain, Infrastructure, Reader package tests pass**

Run from each of `Packages/Domain/`, `Packages/Infrastructure/`, `Packages/Features/Reader/`:

```bash
swift test
```

Expected each: `Test Suite 'All tests' passed`.

If anything fails on a clean checkout, stop and surface — the long-press work shouldn't go on top of a red baseline.

---

## Task 1: Switch `PlaybackController.setCursor` from `ChordPath` to `ScoreCursor`

The new manual cursor must be able to point at a rest. `ChordPath` (system / measure / voice / chord index) cannot represent rests. `PlaybackEngine.seek(to:)` already takes `ScoreCursor`, so going through `ChordPath` would just mean reconstructing data the engine ignores. The current `setCursor(to: ChordPath)` adapter has no caller, so this is safe to swap rather than overload.

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift:13`
- Modify: `Packages/Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift:8,24,55-57`

- [ ] **Step 1: Update the failing test first**

Replace the `lastCursor`/`setCursor` stub in `AudioProtocolsTests.swift` so it expects `ScoreCursor`. Final shape of the relevant lines:

```swift
private final class FakePlaybackController: PlaybackController, @unchecked Sendable {
    var loadedScores = 0
    var lastTempo: Double = 1.0
    var lastCursor: ScoreCursor?
    let cursorContinuation: AsyncStream<ScoreCursor?>.Continuation
    let cursor: AsyncStream<ScoreCursor?>

    init() {
        var c: AsyncStream<ScoreCursor?>.Continuation!
        cursor = AsyncStream { c = $0 }
        cursorContinuation = c
    }

    func load(score: Score, preferences: PlaybackPreferences) throws {
        loadedScores += 1
    }

    func play() throws {}
    func pause() {}
    func setCursor(to cursor: ScoreCursor) { lastCursor = cursor }
    func setLoopRange(_ range: ABRepeatRange?) {}
    func setMetronomeEnabled(_ enabled: Bool) {}
    func setTempoMultiplier(_ value: Double) { lastTempo = value }
    func setStaffVolume(staff: Int, volume: Double) {}
    func setStaffMute(staff: Int, isMuted: Bool) {}
    func setStaffSolo(staff: Int, isSolo: Bool) {}
    func setStaffInstrument(staff: Int, bank: Int, program: Int) {}
}
```

And the test body at line ~53:

```swift
@Test func playbackControllerSetsCursorAndTempo() async throws {
    let controller = FakePlaybackController()
    let target = ScoreCursor.beat(measureIndex: 2, tickInMeasure: 240)
    await controller.setCursor(to: target)
    await controller.setTempoMultiplier(0.75)
    #expect(controller.lastCursor == target)
    #expect(controller.lastTempo == 0.75)
}
```

- [ ] **Step 2: Run the Domain tests — should now fail on the protocol mismatch**

Run from `Packages/Domain/`: `swift test --filter AudioProtocolsTests`

Expected: FAIL — the conformance breaks because the protocol still declares `setCursor(to: ChordPath)`.

- [ ] **Step 3: Update the protocol signature**

In `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift`, replace the `setCursor` declaration:

```swift
func setCursor(to cursor: ScoreCursor) async
```

(`ScoreCursor` is already in scope via the `@_exported import SheetMusicCore` in `DomainExports.swift`.)

- [ ] **Step 4: Run Domain tests again**

Run from `Packages/Domain/`: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift \
        Packages/Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift
git commit -m "refactor(domain): PlaybackController.setCursor takes ScoreCursor"
```

---

## Task 2: Update Reader-side fake controller for the new signature, plus call recording

`FakePlaybackController` lives in the Reader test target and won't compile until it adopts the new signature. We also seed the `recordedSetCursorCalls` array that the next view-model test uses.

**Files:**
- Modify: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift:48`

- [ ] **Step 1: Replace the stub with a recording implementation**

In `FakePlaybackController.swift`, add a new property and replace the stub line:

```swift
private(set) var recordedSetCursorCalls: [ScoreCursor] = []
```

…and replace the existing `func setCursor(to _: ChordPath) {}` with:

```swift
func setCursor(to cursor: ScoreCursor) {
    recordedSetCursorCalls.append(cursor)
}
```

- [ ] **Step 2: Run Reader package tests to confirm they still build/pass**

Run from `Packages/Features/Reader/`: `swift test`
Expected: PASS — the existing tests don't exercise `setCursor`, but the package needs to compile against the new protocol.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift
git commit -m "test(reader): record setCursor(to: ScoreCursor) calls in fake"
```

---

## Task 3: Implement `LivePlaybackController.setCursor` over `PlaybackEngine.seek`

**Files:**
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift:123`

- [ ] **Step 1: Replace the stub with an `engine.seek` call**

Find the line `public func setCursor(to _: ChordPath) {}` (around line 123, in the `// Stubs` block) and replace it with:

```swift
public func setCursor(to cursor: ScoreCursor) {
    engine.seek(to: cursor)
}
```

Move the line out of the `// Stubs — engine doesn't expose these yet` group; the remaining stubs (`setLoopRange`, `setTempoMultiplier`) stay where they are.

- [ ] **Step 2: Run Infrastructure tests to confirm everything still builds and passes**

Run from `Packages/Infrastructure/`: `swift test`
Expected: PASS — no Infrastructure test currently exercises `setCursor`, but the package must compile against the updated protocol.

- [ ] **Step 3: Confirm app project also builds (the swap touched the controller wired into `ReaderView` at the composition root)**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift
git commit -m "feat(audio): forward setCursor to PlaybackEngine.seek"
```

---

## Task 4: Add `nearestCursor(at:in:)` hit-test helper

A pure function over `LayoutDocument`. Lives in the Reader package because the spec is Reader-specific (vertical-mode coords + Reader feature seek).

Algorithm (from spec, restated for the engineer):

1. Pick the system whose Y range contains `point.y`. If none does, pick the closest by Y distance.
2. Within that system, pick the staff whose mid-line (≈ 2 sp below `staffOrigins[i].y`) is closest to `point.y`.
3. Within that system, pick the measure whose X range contains `point.x`. Otherwise the closest by edge.
4. Walk the measure's elements; keep `.chord` and `.rest` whose origin Y lies within ±2.5 sp of the chosen staff centerline. Pick the one whose anchor X is closest to `point.x`. The chord anchor X is `firstNote.origin.x + firstNote.mirrorDx(stem:sp:)`. The rest anchor X is `origin.x`. Both X coordinates are measure-local; add `system.origin.x + measure.origin.x` before comparing to `point.x`.
5. Return `.item(.note(noteID))` for chords (use the **first** `LayoutChordNote`'s `noteID`) or `.item(.rest(restID))` for rests. Return `nil` when step 4 finds no candidate.

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/NearestCursor.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/NearestCursorTests.swift`

- [ ] **Step 1: Write the failing tests first**

Create `Packages/Features/Reader/Tests/ReaderTests/NearestCursorTests.swift`:

```swift
import CoreGraphics
import Foundation
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import Testing

@Suite struct NearestCursorTests {
    private static let sp: CGFloat = 14.0 / 4   // staffSize 14 → sp 3.5

    /// Builds a LayoutDocument with two systems, two staves each.
    /// Each staff has one chord at (x=20) and one rest at (x=60),
    /// inside a single 100-pt-wide measure starting at measure-origin (0,0).
    private static func makeDocument() -> LayoutDocument {
        let metrics = StaffMetrics(staffSize: 14)
        let sp = metrics.sp

        func chord(noteID: NoteID, originY: CGFloat) -> LayoutElement {
            .chord(
                notes: [LayoutChordNote(
                    noteID: noteID, step: 0, accidental: nil,
                    origin: CGPoint(x: 20, y: originY),
                    tieForward: nil, tieBack: nil, hasGlissando: false
                )],
                duration: NoteDuration(base: .quarter, dots: 0),
                stem: .up,
                stemOrigin: CGPoint(x: 20, y: originY),
                hasArpeggio: false, arpeggioRawType: nil,
                isBeamed: false, voiceIndex: 0
            )
        }
        func rest(restID: RestID, originY: CGFloat) -> LayoutElement {
            .rest(
                duration: NoteDuration(base: .quarter, dots: 0),
                origin: CGPoint(x: 60, y: originY),
                voiceIndex: 0, restID: restID, hasLegerLine: false
            )
        }

        // Staff mid-Y is staffOrigin.y + 2 sp.
        // System 0: staffOrigins (0,0) and (0,40). Mids: 2sp, 40+2sp.
        let s0Top = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let s0Bot = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let n0Top = NoteID(staff: s0Top, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)
        let r0Top = RestID(staff: s0Top, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        let n0Bot = NoteID(staff: s0Bot, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)
        let r0Bot = RestID(staff: s0Bot, measureIndex: 0, voiceIndex: 0, elementIndex: 1)

        let measure0 = LayoutMeasure(
            measureIndex: 0,
            origin: .zero,
            width: 100,
            elements: [
                chord(noteID: n0Top, originY: 2 * sp),
                rest(restID: r0Top, originY: 2 * sp),
                chord(noteID: n0Bot, originY: 40 + 2 * sp),
                rest(restID: r0Bot, originY: 40 + 2 * sp),
            ]
        )
        let system0 = LayoutSystem(
            origin: CGPoint(x: 0, y: 0),
            size: CGSize(width: 100, height: 60),
            measures: [measure0],
            staffOrigins: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 40)],
            staffAddresses: [s0Top, s0Bot],
            partLabels: [],
            spanners: [],
            sp: sp
        )

        // System 1: 200 pt below system 0; same staff layout, fresh IDs.
        let s1Top = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let n1Top = NoteID(staff: s1Top, measureIndex: 1, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)
        let r1Top = RestID(staff: s1Top, measureIndex: 1, voiceIndex: 0, elementIndex: 1)
        let measure1 = LayoutMeasure(
            measureIndex: 1,
            origin: .zero,
            width: 100,
            elements: [
                chord(noteID: n1Top, originY: 2 * sp),
                rest(restID: r1Top, originY: 2 * sp),
            ]
        )
        let system1 = LayoutSystem(
            origin: CGPoint(x: 0, y: 200),
            size: CGSize(width: 100, height: 20),
            measures: [measure1],
            staffOrigins: [CGPoint(x: 0, y: 0)],
            staffAddresses: [s1Top],
            partLabels: [],
            spanners: [],
            sp: sp
        )

        return LayoutDocument(
            size: CGSize(width: 100, height: 220),
            systems: [system0, system1],
            metrics: metrics
        )
    }

    @Test func pressOnNoteheadReturnsThatNote() {
        let doc = Self.makeDocument()
        let result = nearestCursor(at: CGPoint(x: 20, y: 2 * Self.sp), in: doc)
        #expect(result == .item(.note(NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0
        ))))
    }

    @Test func pressOnRestReturnsThatRest() {
        let doc = Self.makeDocument()
        let result = nearestCursor(at: CGPoint(x: 60, y: 2 * Self.sp), in: doc)
        #expect(result == .item(.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 1
        ))))
    }

    @Test func pressInGapBetweenStavesPicksNearerStaff() {
        let doc = Self.makeDocument()
        // Top staff mid is at 2 sp; bottom mid is at 40 + 2 sp = ~47.
        // Gap mid Y = (2*sp + 40 + 2*sp) / 2 ≈ 23.5; press a hair below
        // that → should snap to bottom staff.
        let probeY = 2 * Self.sp + (40) / 2 + 1
        let result = nearestCursor(at: CGPoint(x: 20, y: probeY), in: doc)
        #expect(result?.staffOfNote == StaffAddress(partIndex: 1, staffIndexInPart: 0))
    }

    @Test func pressAboveFirstSystemSnapsToFirstSystemFirstEvent() {
        let doc = Self.makeDocument()
        let result = nearestCursor(at: CGPoint(x: 20, y: -50), in: doc)
        #expect(result == .item(.note(NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0
        ))))
    }

    @Test func pressInEmptyMeasureReturnsNil() {
        // Build a one-system document whose only measure has no elements.
        let metrics = StaffMetrics(staffSize: 14)
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let measure = LayoutMeasure(
            measureIndex: 0, origin: .zero, width: 100, elements: []
        )
        let system = LayoutSystem(
            origin: .zero,
            size: CGSize(width: 100, height: 20),
            measures: [measure],
            staffOrigins: [.zero],
            staffAddresses: [staff],
            partLabels: [],
            spanners: [],
            sp: metrics.sp
        )
        let doc = LayoutDocument(
            size: CGSize(width: 100, height: 20),
            systems: [system], metrics: metrics
        )
        #expect(nearestCursor(at: CGPoint(x: 20, y: 2 * metrics.sp), in: doc) == nil)
    }
}

private extension ScoreCursor {
    /// Helper for asserting on `.item(.note(_))` results — only valid
    /// for the test cases that produce a note cursor.
    var staffOfNote: StaffAddress? {
        if case let .item(.note(id)) = self { return id.staff }
        return nil
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail with "no such symbol"**

Run from `Packages/Features/Reader/`: `swift test --filter NearestCursorTests`
Expected: FAIL — `nearestCursor` is not defined.

- [ ] **Step 3: Implement `NearestCursor.swift`**

Create `Packages/Features/Reader/Sources/Reader/NearestCursor.swift`:

```swift
import CoreGraphics
import SheetMusicCore
import SheetMusicLayout

/// Maps a point in `LayoutDocument` coordinates to the nearest
/// playable cursor (a chord onset or a rest) on the staff closest to
/// the touch.
///
/// Returns `nil` when the chosen system / staff / measure has no
/// playable elements (e.g. an empty staff under the touched X).
@available(macOS 15.0, iOS 16.0, *)
func nearestCursor(at point: CGPoint, in document: LayoutDocument) -> ScoreCursor? {
    guard let system = chooseSystem(forY: point.y, in: document.systems) else {
        return nil
    }
    let sp = system.sp
    guard let staffMidY = chooseStaffMidY(
        forY: point.y, system: system, sp: sp
    ) else {
        return nil
    }
    guard let measure = chooseMeasure(forX: point.x, system: system) else {
        return nil
    }
    return chooseEvent(
        in: measure, system: system,
        staffMidY: staffMidY, point: point, sp: sp
    )
}

@available(macOS 15.0, iOS 16.0, *)
private func chooseSystem(
    forY y: CGFloat, in systems: [LayoutSystem]
) -> LayoutSystem? {
    guard !systems.isEmpty else { return nil }
    if let containing = systems.first(where: {
        y >= $0.origin.y && y <= $0.origin.y + $0.size.height
    }) {
        return containing
    }
    return systems.min { lhs, rhs in
        verticalDistance(y: y, system: lhs) < verticalDistance(y: y, system: rhs)
    }
}

@available(macOS 15.0, iOS 16.0, *)
private func verticalDistance(y: CGFloat, system: LayoutSystem) -> CGFloat {
    if y < system.origin.y { return system.origin.y - y }
    let bottom = system.origin.y + system.size.height
    if y > bottom { return y - bottom }
    return 0
}

/// Returns the chosen staff's mid-Y in document coordinates.
/// A 5-line staff is 4 sp tall, so the centerline sits 2 sp below
/// `staffOrigins[i].y`.
@available(macOS 15.0, iOS 16.0, *)
private func chooseStaffMidY(
    forY y: CGFloat, system: LayoutSystem, sp: CGFloat
) -> CGFloat? {
    guard !system.staffOrigins.isEmpty else { return nil }
    let mids = system.staffOrigins.map { system.origin.y + $0.y + 2 * sp }
    return mids.min { lhs, rhs in abs(y - lhs) < abs(y - rhs) }
}

@available(macOS 15.0, iOS 16.0, *)
private func chooseMeasure(
    forX x: CGFloat, system: LayoutSystem
) -> LayoutMeasure? {
    guard !system.measures.isEmpty else { return nil }
    if let containing = system.measures.first(where: { measure in
        let lo = system.origin.x + measure.origin.x
        let hi = lo + measure.width
        return x >= lo && x <= hi
    }) {
        return containing
    }
    return system.measures.min { lhs, rhs in
        horizontalDistance(x: x, system: system, measure: lhs)
            < horizontalDistance(x: x, system: system, measure: rhs)
    }
}

@available(macOS 15.0, iOS 16.0, *)
private func horizontalDistance(
    x: CGFloat, system: LayoutSystem, measure: LayoutMeasure
) -> CGFloat {
    let lo = system.origin.x + measure.origin.x
    let hi = lo + measure.width
    if x < lo { return lo - x }
    if x > hi { return x - hi }
    return 0
}

@available(macOS 15.0, iOS 16.0, *)
private func chooseEvent(
    in measure: LayoutMeasure,
    system: LayoutSystem,
    staffMidY: CGFloat,
    point: CGPoint,
    sp: CGFloat
) -> ScoreCursor? {
    let baseX = system.origin.x + measure.origin.x
    let baseY = system.origin.y + measure.origin.y
    let staffYBand: CGFloat = 2.5 * sp

    var best: (cursor: ScoreCursor, dx: CGFloat)?
    for element in measure.elements {
        switch element {
        case let .chord(notes, _, stem, _, _, _, _, _):
            guard let first = notes.first else { continue }
            let elementY = baseY + first.origin.y
            guard abs(elementY - staffMidY) <= staffYBand else { continue }
            let anchorX = baseX + first.origin.x + first.mirrorDx(stem: stem, sp: sp)
            let dx = abs(anchorX - point.x)
            if best == nil || dx < best!.dx {
                best = (.item(.note(first.noteID)), dx)
            }
        case let .rest(_, origin, _, restID, _):
            let elementY = baseY + origin.y
            guard abs(elementY - staffMidY) <= staffYBand else { continue }
            let anchorX = baseX + origin.x
            let dx = abs(anchorX - point.x)
            if best == nil || dx < best!.dx {
                best = (.item(.rest(restID)), dx)
            }
        default:
            continue
        }
    }
    return best?.cursor
}
```

- [ ] **Step 4: Run the tests — should pass**

Run from `Packages/Features/Reader/`: `swift test --filter NearestCursorTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full Reader package test suite to confirm no regression**

Run from `Packages/Features/Reader/`: `swift test`
Expected: all suites pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/NearestCursor.swift \
        Packages/Features/Reader/Tests/ReaderTests/NearestCursorTests.swift
git commit -m "feat(reader): nearestCursor(at:in:) hit-test helper"
```

---

## Task 5: Add `ReaderViewModel.setManualCursor(_:)`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelManualCursorTests.swift`

- [ ] **Step 1: Write the failing tests first**

Create `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelManualCursorTests.swift`:

```swift
import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@Suite @MainActor
struct ReaderViewModelManualCursorTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: "t.mscx", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    @Test func setManualCursorUpdatesPlaybackCursorImmediately() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        let cursor = ScoreCursor.beat(measureIndex: 3, tickInMeasure: 120)
        vm.setManualCursor(cursor)
        #expect(vm.playbackCursor == cursor)
    }

    @Test func setManualCursorForwardsToControllerExactlyOnce() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        let cursor = ScoreCursor.beat(measureIndex: 1, tickInMeasure: 0)
        vm.setManualCursor(cursor)
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(controller.recordedSetCursorCalls == [cursor])
    }

    @Test func setManualCursorWithNoControllerOnlyUpdatesLocalCursor() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: nil
        )
        let cursor = ScoreCursor.beat(measureIndex: 7, tickInMeasure: 0)
        vm.setManualCursor(cursor)
        #expect(vm.playbackCursor == cursor)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `Packages/Features/Reader/`: `swift test --filter ReaderViewModelManualCursorTests`
Expected: FAIL — `setManualCursor` is not defined.

- [ ] **Step 3: Implement `setManualCursor`**

In `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`, add a public method just below `toggleChrome()` (around line 205):

```swift
public func setManualCursor(_ cursor: ScoreCursor) {
    playbackCursor = cursor
    guard let controller = playbackController else { return }
    Task { await controller.setCursor(to: cursor) }
}
```

The local write before the `Task` is intentional — see the spec under "ReaderViewModel API" — it gives instant visual feedback even when no controller is wired (previews / headless tests).

- [ ] **Step 4: Run the tests — should pass**

Run from `Packages/Features/Reader/`: `swift test --filter ReaderViewModelManualCursorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full Reader test suite to confirm no regression**

Run from `Packages/Features/Reader/`: `swift test`
Expected: all suites pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelManualCursorTests.swift
git commit -m "feat(reader): ReaderViewModel.setManualCursor"
```

---

## Task 6: Wire long-press gesture in `VerticalScoreContainer`

The score surface gets a named coord space `"scoreSurface"`, and a composed gesture (`DragGesture` + `LongPressGesture`) reads its location in that space. On success the gesture asks `nearestCursor(at:in:)` and forwards the result to `ReaderViewModel.setManualCursor(_:)`. A `.sensoryFeedback(.impact(weight: .medium), trigger:)` modifier fires a haptic when the cursor actually moved.

`VerticalScoreContainer` doesn't hold the view model today — it takes only `score`, `staffSize`, `playbackCursor`. We pass the view model in so the gesture can call `setManualCursor` directly, instead of plumbing a callback up through `ReaderView`. Update `ReaderView` accordingly.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderView.swift:99-105`

- [ ] **Step 1: Add `viewModel` parameter to `VerticalScoreContainer`**

In `VerticalScoreContainer.swift`, change the stored properties at the top of the struct:

```swift
struct VerticalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var lastWidth: CGFloat = 0
    @State private var systemFrames: [Int: CGRect] = [:]
    @State private var lastManualCursor: ScoreCursor?
    // ...
```

(The `lastManualCursor` state is the trigger source for `.sensoryFeedback`; bumping it asks SwiftUI to play the haptic.)

- [ ] **Step 2: Add the named coord space and the long-press gesture to `scoreSurface`**

Replace the existing `scoreSurface` body in `VerticalScoreContainer.swift` so the score surface declares `coordinateSpace(.named("scoreSurface"))` and attaches the gesture:

```swift
@ViewBuilder
private var scoreSurface: some View {
    if let doc = document {
        ZStack(alignment: .topLeading) {
            ScoreView(
                document: doc, score: score,
                playbackCursor: playbackCursor
            )
            VerticalSystemAnchors(document: doc)
        }
        .coordinateSpace(name: "scoreSurface")
        .gesture(longPressSeekGesture(document: doc))
        .sensoryFeedback(.impact(weight: .medium), trigger: lastManualCursor)
    } else {
        Color.clear
    }
}
```

- [ ] **Step 3: Add the gesture builder + state for the live drag location**

Inside `VerticalScoreContainer`, declare a `@GestureState` for the drag location, and add `longPressSeekGesture(document:)`:

```swift
@GestureState private var seekProbeLocation: CGPoint?

private func longPressSeekGesture(document: LayoutDocument) -> some Gesture {
    let drag = DragGesture(minimumDistance: 0, coordinateSpace: .named("scoreSurface"))
        .updating($seekProbeLocation) { value, state, _ in
            state = value.location
        }
    let longPress = LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
        .onEnded { _ in
            guard let probe = seekProbeLocation,
                  let cursor = nearestCursor(at: probe, in: document)
            else { return }
            viewModel.setManualCursor(cursor)
            lastManualCursor = cursor
        }
    return drag.simultaneously(with: longPress)
}
```

A `DragGesture` with `minimumDistance: 0` carries the touch location even for a stationary press. `LongPressGesture(maximumDistance: 10)` cancels if the finger drifts more than 10 pt during the hold, which matches the spec's "movement > 10 pt cancels".

- [ ] **Step 4: Update the call site in `ReaderView` to pass `viewModel`**

In `Packages/Features/Reader/Sources/Reader/ReaderView.swift`, in the `case .vertical:` branch, replace:

```swift
case .vertical:
    VerticalScoreContainer(
        score: visible,
        staffSize: viewModel.preferences.staffSize,
        playbackCursor: viewModel.playbackCursor
    )
```

with:

```swift
case .vertical:
    VerticalScoreContainer(
        score: visible,
        staffSize: viewModel.preferences.staffSize,
        playbackCursor: viewModel.playbackCursor,
        viewModel: viewModel
    )
```

- [ ] **Step 5: Run the Reader package tests to confirm everything still builds**

Run from `Packages/Features/Reader/`: `swift test`
Expected: all suites pass. (Gesture wiring is verified manually below.)

- [ ] **Step 6: Build the app project**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift \
        Packages/Features/Reader/Sources/Reader/ReaderView.swift
git commit -m "feat(reader): long-press to move cursor in vertical mode"
```

---

## Task 7: Manual simulator verification

Swift Testing can't drive `LongPressGesture`, so the gesture wiring (location capture under transforms, haptic firing, seek under playback) is verified by hand once.

**Files:** none.

- [ ] **Step 1: Boot the simulator and run the app**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
xcrun simctl boot 'iPhone 16' 2>/dev/null || true
open -a Simulator
xcrun simctl install booted \
  "$(xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -showBuildSettings build 2>/dev/null | awk -F= '/ BUILT_PRODUCTS_DIR /{print $2}' | xargs)/Folino.app"
xcrun simctl launch booted com.KeyNumber.Folino
```

(If the user has a faster local launch ritual, follow that — the build settings probe above is just an explicit fallback.)

- [ ] **Step 2: Hand control back to the user with a test checklist**

Tell the user to verify, in vertical mode, with a real `.mscx` open:

1. Stopped: long-press a notehead → cursor highlight jumps to it; medium haptic fires; tap "play" → audio starts at that note.
2. Stopped: long-press a rest → cursor jumps to the rest.
3. Stopped: long-press the gap between two staves → cursor lands on the closer staff.
4. Stopped: long-press above the first system → cursor lands on the first event.
5. Playing: long-press far ahead of the current cursor → audio jumps and continues.
6. Plain tap (no hold) → still toggles chrome (does not move the cursor).
7. Long-press while pinching → pinch is unaffected; if the finger moves > 10 pt before the long-press fires, no cursor change.

If anything misbehaves (especially #5 — the sequencer seek), come back and debug; do not check this task off until the user confirms.

- [ ] **Step 3: Document the manual verification result in the commit message**

Once the user confirms behaviour:

```bash
git commit --allow-empty -m "chore(reader): verify long-press cursor seek in simulator"
```

---

## Task 8: Open PR

**Files:** none.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/reader-long-press-cursor
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "feat(reader): long-press to move playback cursor (vertical mode)" --body "$(cat <<'EOF'
## Summary
- Long-press anywhere on the score in vertical layout snaps the playback cursor to the nearest note or rest on the closest staff.
- When playback is running, the audio engine seeks too — visual + audible.
- A medium-weight sensory feedback fires on a successful seek.

## Test plan
- [ ] `swift test` passes in `Packages/Domain`, `Packages/Infrastructure`, `Packages/Features/Reader`.
- [ ] Manual simulator pass (see Task 7 in the implementation plan): long-press on note / rest / inter-staff gap / above the first system; long-press during playback seeks audio; plain tap still toggles chrome; pinch unaffected.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Surface the PR URL to the user**

The `gh pr create` invocation prints the PR URL on stdout. Echo it back so the user can click through.

---

## Self-review check

Spec requirements covered:

- Vertical-only scope, page-mode untouched → Task 6 only modifies `VerticalScoreContainer` + the `.vertical` arm of `ReaderView.content`. ✔
- Long-press snaps cursor to nearest playable event on closest staff → Tasks 4 (helper), 5 (view-model wiring), 6 (gesture wiring). ✔
- Medium haptic on success → Task 6 step 2/3 (`.sensoryFeedback`). ✔
- Long-press doesn't toggle chrome → Tap is `SpatialTapGesture(count: 1)` in the existing `ReaderGestureLayer`; the long-press lives one layer down on the score surface inside `ScrollView`, so the tap and long-press don't conflict. ✔ (Documented in spec under "Why score surface, not gesture layer".)
- Pinch unaffected → New gesture sits on the `scoreSurface` *inside* the `ScrollView`. The existing `MagnifyGesture` lives on the wrapping `ReaderGestureLayer`. They run independently. Manual check at Task 7 step 2 #7. ✔
- `nearestCursor` algorithm: system → staff (mid-Y) → measure → element (chord/rest, ±2.5 sp Y band, nearest X) → `.item(...)` → Task 4 step 3. ✔
- Press above first system snaps to system 0 → `chooseSystem` returns the closest by Y when no system contains the point. Tested in Task 4 step 1. ✔
- Empty staff at touched X → returns `nil`; view-model no-op. Tested in Task 4 step 1. ✔
- Domain change `setCursor(to: ChordPath)` → `setCursor(to: ScoreCursor)` → Task 1. ✔
- `LivePlaybackController.setCursor` → `engine.seek(to:)` → Task 3. ✔
- `setManualCursor` immediate visual + forwarded seek + nil-controller path → Task 5 with all three test cases. ✔
- Manual cursor while playing follows engine republish via existing `cursor` stream → no new code; existing wiring at `ReaderViewModel.startObservingCursor` already does this. Manual check at Task 7 step 2 #5. ✔
- Out-of-scope items (page mode, drag-scrub, A–B repeat, undo) — none of the tasks touch them. ✔

No placeholders. No `TBD`s. Method signatures are consistent across tasks (`setCursor(to: ScoreCursor)`, `setManualCursor(_ cursor: ScoreCursor)`, `nearestCursor(at:in:)`).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-06-reader-long-press-cursor.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
