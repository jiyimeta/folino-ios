# Android Tap-to-Seek + Tap-Audition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tapping a note in the Android Reader moves the playback cursor and auditions that note for ~0.5 s while paused, matching iOS, by sharing the hit-test + cursor-translation logic in swift-sheet-music.

**Architecture:** Lift `nearestCursor` + filtered→full cursor translation into swift-sheet-music (iOS adopts the shared copy); expose a `nativeNearestCursor` JNI bridge; the Android Compose Reader converts a tap to document-mm, calls the bridge, and feeds the resulting engine-ready cursor to `seek` + (when paused) `playPreview`.

**Tech Stack:** Swift 6.3 (SheetMusicCore / SheetMusicLayout / SheetMusicAndroidJNI), swift-java/jextract JNI, Kotlin + Jetpack Compose (FolinoReaderAndroid), AVFoundation/FluidSynth engines.

**Repos / worktrees:**
- ssm worktree (create at execution): base `de5c7c6` (current Folino pin = origin/main tip), branch `feat/shared-nearest-cursor`.
- Folino worktree: `worktree-android-tap-seek-audition` (already created).

**Cross-repo gates:** ssm push only on user approval; Folino re-pins after push. Android verified by install+launch on a physical Pixel.

---

## File Structure

**swift-sheet-music (Part 1):**
- Create `Sources/SheetMusicLayout/NearestCursor.swift` — `nearestCursor(at:in:)` (public) + `nearestEngineCursor(at:in:score:hiddenStaves:)` (public).
- Create `Sources/SheetMusicCore/Score/Score+FilteredTapCursor.swift` — `Score.engineCursorForFilteredTap(_:hiddenStaves:)` + `Score.unfilterStaffAddress(_:hidingStaves:)` (public).
- Create `Sources/SheetMusicAndroidJNI/NearestCursorBridge.swift` — `nativeNearestCursor(...)`.
- Create `Sources/SheetMusicAndroidJNI/StaffAddressSetCodec.swift` — encode/decode `Set<StaffAddress>` (if no existing codec is directly reusable).
- Create `Tests/SheetMusicTests/NearestEngineCursorTests.swift`.
- Android Kotlin binding: `Android/SheetMusicAndroid/src/main/kotlin/.../SheetMusicJNI.kt` — add `nativeNearestCursor`.

**Folino-iOS (Part 2 — iOS adoption):**
- Delete `Packages/Features/Reader/Sources/Reader/NearestCursor.swift`.
- Modify `Packages/Features/Reader/Sources/Reader/Score+CursorTranslation.swift` — remove `engineCursorForFilteredTap` (now from ssm); keep `translateCursorForHiddenStaves`.
- Modify `Packages/Features/Reader/Sources/Reader/Score+UnfilteredStaffAddress.swift` — remove `unfilterStaffAddress` (now from ssm); keep `filterStaffAddress`.
- Re-pin: `project.yml` + `Packages/{Domain,Infrastructure,Features/Reader,Features/Library}/Package.swift`.

**Folino-iOS (Part 3 — Android UI):**
- Modify `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt` — `handleTap(cursor)`.
- Modify `.../reader/ReaderScreen.kt` (vertical + horizontal surfaces) — tap detectors.
- Modify `.../reader/PagedScore.kt` + `PageTapOverlay.kt` — center-region tap detector.
- Possibly a small `.../reader/TapToCursor.kt` helper for px→mm + JNI call shared by the three modes.

---

## Part 1 — swift-sheet-music: shared logic + JNI

### Task 1: Lift the Score address helper into SheetMusicCore

**Files:**
- Create: `Sources/SheetMusicCore/Score/Score+FilteredTapCursor.swift`

- [ ] **Step 1: Create the file with the two functions (made public), copied verbatim from Folino**

```swift
import Foundation

extension Score {
    /// `nearestCursor` runs against a `LayoutDocument` built from the filtered score, so the
    /// `StaffAddress` it stamps onto `NoteID` / `RestID` is positional within the filtered parts. The
    /// playback engine's timeline is keyed by the full-score address, so a tap-derived cursor must be
    /// re-addressed before being handed to the engine. `.beat` cursors carry no staff address and pass
    /// through unchanged.
    public func engineCursorForFilteredTap(
        _ cursor: ScoreCursor, hiddenStaves hidden: Set<StaffAddress>
    ) -> ScoreCursor {
        guard !hidden.isEmpty,
              case let .item(id) = cursor,
              let full = unfilterStaffAddress(id.staff, hidingStaves: hidden)
        else { return cursor }
        switch id {
        case let .note(noteID):
            return .item(.note(NoteID(
                staff: full, measureIndex: noteID.measureIndex, voiceIndex: noteID.voiceIndex,
                elementIndex: noteID.elementIndex, noteIndexInChord: noteID.noteIndexInChord,
            )))
        case let .rest(restID):
            return .item(.rest(RestID(
                staff: full, measureIndex: restID.measureIndex, voiceIndex: restID.voiceIndex,
                elementIndex: restID.elementIndex,
            )))
        case .tuplet, .clef:
            return cursor
        }
    }

    /// Inverse of the part/staff renumbering performed by `filtered(hidingStaves:)`: given a
    /// `StaffAddress` produced against the filtered score, return the address in this (unfiltered)
    /// score, or `nil` when it can't be located under the current visibility.
    public func unfilterStaffAddress(
        _ filtered: StaffAddress, hidingStaves hidden: Set<StaffAddress>
    ) -> StaffAddress? {
        guard !hidden.isEmpty else { return filtered }
        var newPartIdx = 0
        for (origPartIdx, part) in parts.enumerated() {
            let surviving = part.staves.indices.filter { sIdx in
                !hidden.contains(StaffAddress(partIndex: origPartIdx, staffIndexInPart: sIdx))
            }
            guard !surviving.isEmpty else { continue }
            if newPartIdx == filtered.partIndex {
                guard surviving.indices.contains(filtered.staffIndexInPart) else { return nil }
                return StaffAddress(
                    partIndex: origPartIdx, staffIndexInPart: surviving[filtered.staffIndexInPart],
                )
            }
            newPartIdx += 1
        }
        return nil
    }
}
```

- [ ] **Step 2: Build the target**

Run: `swift build --package-path <ssm-worktree> --target SheetMusicCore`
Expected: builds (these functions only use `Score`/`StaffAddress`/`NoteID`/`RestID`/`ScoreCursor`, all in SheetMusicCore).

- [ ] **Step 3: Commit**

```bash
git -C <ssm-worktree> add Sources/SheetMusicCore/Score/Score+FilteredTapCursor.swift
git -C <ssm-worktree> commit -m "feat(core): share filtered-tap cursor translation"
```

### Task 2: Lift nearestCursor + add nearestEngineCursor into SheetMusicLayout

**Files:**
- Create: `Sources/SheetMusicLayout/NearestCursor.swift`

- [ ] **Step 1: Create the file** — copy Folino's `NearestCursor.swift` verbatim (the `nearestCursor` + all four `private` helpers `chooseSystem`/`chooseStaffMidY`/`chooseMeasure`/`chooseEvent`/`verticalDistance`/`horizontalDistance`), change `nearestCursor` to `public`, and append:

```swift
/// Hit-test a tap against the (filtered) layout and return an engine-ready, full-score-addressed
/// cursor — the single entry point both iOS and the Android JNI bridge call.
@available(macOS 15.0, iOS 16.0, *)
public func nearestEngineCursor(
    at point: CGPoint, in document: LayoutDocument,
    score: Score, hiddenStaves: Set<StaffAddress>
) -> ScoreCursor? {
    guard let cursor = nearestCursor(at: point, in: document) else { return nil }
    return score.engineCursorForFilteredTap(cursor, hiddenStaves: hiddenStaves)
}
```

(The copied `chooseEvent` references `LayoutElement` chord/rest associated-value shapes and
`LayoutNote.mirrorDx(stem:sp:)` / `.noteID` — all in SheetMusicLayout, so no changes needed.)

- [ ] **Step 2: Build**

Run: `swift build --package-path <ssm-worktree> --target SheetMusicLayout`
Expected: builds. If `mirrorDx` / `.noteID` were `internal` to a different module they'd error — they are in SheetMusicLayout, so this confirms the lift is self-contained.

- [ ] **Step 3: Commit**

```bash
git -C <ssm-worktree> add Sources/SheetMusicLayout/NearestCursor.swift
git -C <ssm-worktree> commit -m "feat(layout): share nearestCursor + nearestEngineCursor"
```

### Task 3: Unit-test nearestEngineCursor

**Files:**
- Create: `Tests/SheetMusicTests/NearestEngineCursorTests.swift`

- [ ] **Step 1: Write failing tests** — build a 2-staff score, compute its `LayoutDocument` (use the same layout-compute entry the existing layout tests use; read `Tests/SheetMusicTests/` for the helper, e.g. `LayoutEngine`/`computeWithDocument`), then:

```swift
#if !os(Android)
import CoreGraphics
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("nearestEngineCursor") @MainActor
struct NearestEngineCursorTests {
    // makeScore(): 2 parts, 1 staff each, each measure one quarter-note chord at a known pitch.
    // layout(score): compute LayoutDocument via the project's layout API.

    @Test("tap on a note returns that note") func tapNote() throws {
        // place a tap at the document point of a known note (read from LayoutDocument), assert
        // result == .item(.note(expectedNoteID)).
    }

    @Test("tap with a hidden staff returns a full-score address") func tapHidden() throws {
        // layout the filtered score (hide part 0 staff 0), tap a surviving-staff note, assert the
        // returned NoteID.staff is the FULL-score address (partIndex restored), not the filtered one.
    }

    @Test("tap in empty space returns nil") func tapEmpty() throws {
        // tap far outside any system → nil.
    }
}
#endif
```

- [ ] **Step 2: Run, expect FAIL/compile-driven RED**

Run: `swift test --package-path <ssm-worktree> --filter NearestEngineCursor`
Expected: tests fail until the score/layout fixtures + assertions are filled against real coordinates (iterate: print the LayoutDocument note origins, set the tap point, assert).

- [ ] **Step 3: Make them pass** by filling fixtures from the real layout coordinates (no production change needed — Tasks 1–2 already provide the API).

Run: `swift test --package-path <ssm-worktree> --filter NearestEngineCursor`
Expected: PASS.

- [ ] **Step 4: Regression** — `swift test --package-path <ssm-worktree> --filter PlaybackEngine` → all green.

- [ ] **Step 5: Commit**

```bash
git -C <ssm-worktree> add Tests/SheetMusicTests/NearestEngineCursorTests.swift
git -C <ssm-worktree> commit -m "test(layout): nearestEngineCursor hit-test + hidden-staff translation"
```

### Task 4: StaffAddress set codec (JNI)

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/StaffAddressSetCodec.swift`

- [ ] **Step 1: Read existing hidden-staves wire handling** — check how `nativeComputeLayout` receives hidden staves (grep `SheetMusicAndroidJNI` for `hidden`/`StaffAddress`/`HiddenStaff`). If a codec already decodes `Set<StaffAddress>` from `Data`, reuse it and SKIP this task.

- [ ] **Step 2: If none, create a minimal codec**

```swift
import Foundation
import SheetMusicCore

/// Wire format for a set of staff addresses: u16 count, then count × (i32 partIndex, i32 staffIndexInPart),
/// little-endian. Mirrors the Kotlin encoder on the Android side.
public enum StaffAddressSetCodec {
    public static func decode(_ data: Data) -> Set<StaffAddress> {
        var out: Set<StaffAddress> = []
        var i = data.startIndex
        func u16() -> Int? { /* read 2 LE bytes */ }
        func i32() -> Int? { /* read 4 LE bytes */ }
        guard let count = u16() else { return [] }
        for _ in 0 ..< count {
            guard let p = i32(), let s = i32() else { break }
            out.insert(StaffAddress(partIndex: p, staffIndexInPart: s))
        }
        return out
    }
}
```

(Fill the byte-reading helpers concretely against `Data` indices when implementing; match whatever
encoding the Kotlin side already uses for hidden staves so the two agree.)

- [ ] **Step 3: Build + commit** target SheetMusicAndroidJNI (host build).

### Task 5: nativeNearestCursor bridge

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/NearestCursorBridge.swift`

- [ ] **Step 1: Read a sibling bridge** — open `Sources/SheetMusicAndroidJNI/CursorBridge.swift` and `MeasureBridge.swift` to copy the exact conventions: how `scoreHandle` resolves to a `Score`, how `LayoutDocumentCache.value(for:)` is used, the pt↔mm factor, and the `Data` return idiom.

- [ ] **Step 2: Write the bridge**

```swift
import CoreGraphics
import Foundation
import SheetMusicCore
import SheetMusicLayout

/// Hit-test a tap (in document millimeters) against the cached filtered layout and return an
/// engine-ready ScoreCursor (ScoreCursorCodec-encoded), or empty Data when the tap hit nothing.
public func nativeNearestCursor(
    scoreHandle: Int64, tapXmm: Double, tapYmm: Double, hiddenStavesBytes: Data
) -> Data {
    guard let document = LayoutDocumentCache.value(for: scoreHandle),
          let score = /* resolve Score for handle — copy from CursorBridge */ nil as Score?
    else { return Data() }
    let ptPerMM = 72.0 / 25.4
    let point = CGPoint(x: tapXmm * ptPerMM, y: tapYmm * ptPerMM)
    let hidden = StaffAddressSetCodec.decode(hiddenStavesBytes)
    guard let cursor = nearestEngineCursor(
        at: point, in: document, score: score, hiddenStaves: hidden,
    ) else { return Data() }
    return ScoreCursorCodec.encode(cursor)
}
```

(Replace the `Score`-resolution placeholder with the exact registry call used by `CursorBridge` —
identified in Step 1.)

- [ ] **Step 3: Build SheetMusicAndroidJNI (host) + commit.**

### Task 6: Kotlin JNI binding

**Files:**
- Modify: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt`

- [ ] **Step 1: Read the existing `nativeCursorFrame` binding** in this file to copy the jextract external-function signature + `ByteArray`/`Data` marshaling.
- [ ] **Step 2: Add** `fun nativeNearestCursor(scoreHandle: Long, tapXmm: Double, tapYmm: Double, hiddenStavesBytes: ByteArray): ByteArray` following that pattern.
- [ ] **Step 3: Regenerate jextract bindings / cross-compile** per `Scripts/android-build-libs.sh` conventions (the project's documented Android build path). Commit.

---

## Part 2 — ssm push gate + Folino iOS adoption

### Task 7: Verify ssm and request push

- [ ] **Step 1:** `swift test --package-path <ssm-worktree> --filter "NearestEngineCursor|PlaybackEngine"` → green.
- [ ] **Step 2:** Report the change + test evidence to the user; **wait for push approval** (cross-repo gate).
- [ ] **Step 3 (on approval):** push the ssm branch (FF onto origin/main if origin/main is still de5c7c6, else rebase first). Record the new revision `<SSM_REV>`.

### Task 8: Folino re-pin + delete duplicated iOS logic

**Files:**
- Modify: `project.yml`, `Packages/{Domain,Infrastructure,Features/Reader,Features/Library}/Package.swift` → `<SSM_REV>`.
- Delete: `Packages/Features/Reader/Sources/Reader/NearestCursor.swift`.
- Modify: `Score+CursorTranslation.swift` (remove `engineCursorForFilteredTap`), `Score+UnfilteredStaffAddress.swift` (remove `unfilterStaffAddress`).

- [ ] **Step 1:** Re-pin all 5 files to `<SSM_REV>`.
- [ ] **Step 2:** Delete `NearestCursor.swift`; remove `engineCursorForFilteredTap` from `Score+CursorTranslation.swift` and `unfilterStaffAddress` from `Score+UnfilteredStaffAddress.swift` (keep `translateCursorForHiddenStaves`, `filterStaffAddress`, `resolveTickInMeasure`).
- [ ] **Step 3:** `xcodegen generate --spec <folino-worktree>/project.yml`.
- [ ] **Step 4:** Build app — `xcodebuild -project <folino-worktree>/Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build` → BUILD SUCCEEDED. (Confirms the surfaces resolve `nearestCursor` and `setManualCursor` resolves `engineCursorForFilteredTap` from ssm.)
- [ ] **Step 5:** Reader tests — `xcodebuild test -workspace <folino-worktree>/Packages/Features/Reader -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:ReaderTests/NearestCursorTests -only-testing:ReaderTests/ReaderPlaybackSessionAuditionTests -only-testing:ReaderTests/ReaderViewModelHiddenStaffCursorTests` → green.
- [ ] **Step 6:** Commit re-pin + deletions.

---

## Part 3 — Android UI

### Task 9: ReaderAudioViewModel.handleTap

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt`

- [ ] **Step 1: Read** the file for the exact `ScoreCursor`/`ScoreItemID` Kotlin sealed types, `state` flow, `seek`, and `playPreview` signatures.
- [ ] **Step 2: Add**

```kotlin
fun handleTap(cursor: ScoreCursor) {
    engine?.seek(to = cursor)
    val playing = state.value == PlaybackState.PLAYING
    val noteId = (cursor as? ScoreCursor.Item)?.let { it.id as? ScoreItemID.Note }?.noteId
    if (!playing && noteId != null) engine?.playPreview(noteId, durationMillis = 500)
}
```

(Adjust to the real sealed-type names found in Step 1.)
- [ ] **Step 3: Build** the Android Reader module (`Scripts/android-build-libs.sh` path) — compiles.
- [ ] **Step 4: Commit.**

### Task 10: px→mm tap helper + JNI call

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/TapToCursor.kt`

- [ ] **Step 1: Read** `ReaderScreen.kt` / `PagedScore.kt` to find the render transform state (fit-scale, user zoom, scroll offset, page-Y in mm) so px→mm is derived from the SAME values the renderer uses — do NOT assume factors.
- [ ] **Step 2: Write** a helper that takes (tap Offset px, the mode's transform state, scoreHandle, hiddenStavesBytes) → decoded `ScoreCursor?` by converting px→document-mm and calling `SheetMusicJNI.nativeNearestCursor` + `ScoreCursorCodec.decode`. Return null on empty bytes.
- [ ] **Step 3: Commit.**

### Task 11: Vertical + horizontal tap detectors

**Files:**
- Modify: `ReaderScreen.kt` (vertical ScorePage + HorizontalScore).

- [ ] **Step 1:** Add `Modifier.pointerInput(Unit) { detectTapGestures { offset -> ... } }` to each ScorePage that calls the Task-10 helper and forwards the cursor to `viewModel.handleTap`. Ensure it doesn't break the existing pinch-zoom (`detectTapGestures` and the transform `pointerInput` can coexist on separate modifiers / keys).
- [ ] **Step 2:** Build the Android Reader module — compiles.
- [ ] **Step 3:** Commit.

### Task 12: Paged center-region tap

**Files:**
- Modify: `PagedScore.kt`, `PageTapOverlay.kt`.

- [ ] **Step 1: Read** `PageTapOverlay.kt` for the left/right nav-zone widths.
- [ ] **Step 2:** Add a center-region tap detector (page width minus the two nav-zone widths) that converts the page-local offset to absolute document-mm (page-Y band from `breaksMm[pageIndex]`) via the Task-10 helper and calls `handleTap`. Left/right zones keep page navigation.
- [ ] **Step 3:** Build — compiles. Commit.

### Task 13: Pixel verification

- [ ] **Step 1:** Build + `installDebug` + `adb shell am start` on a physical Pixel (per the Android workflow rule — Claude does install+launch).
- [ ] **Step 2:** Manually confirm in each mode: tap a note → cursor moves; while paused → the note sounds (~0.5 s); rest tap → cursor moves, silent; paged edges still turn pages, center seeks. Hidden-staff case via Display Inspector → correct note sounds.
- [ ] **Step 3:** Report results.

---

## Finish

- [ ] Merge ssm branch to its main line (per user's branch policy) and Folino branch to local main, both via the finishing-a-development-branch flow.
- [ ] Update memory: feature done, ssm revision, any pitfalls.
- [ ] Cleanup both worktrees.

## Notes on deferred specifics (read-then-implement, not placeholders)

Three details are intentionally resolved by reading code at the task where they're needed, because
fabricating them would be wrong: (a) the exact `Score`-from-handle call in the JNI bridge (Task 5,
copied from `CursorBridge`); (b) the hidden-staves wire encoding to match Kotlin (Task 4); (c) the
Android px→document-mm transform values (Task 10, read from the renderer). Each task names the file to
read and what to extract.
