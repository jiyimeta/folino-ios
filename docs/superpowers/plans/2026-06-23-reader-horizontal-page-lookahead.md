# Reader horizontal + page lookahead follow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add anticipatory follow to the Reader's horizontal and page modes on iOS and Android: horizontal left-aligns the playing measure ~2 beats early (2-stage trigger); page turns to the 1-beat-lookahead cursor's page (virtual-only trigger).

**Architecture:** Reuse-only. Horizontal calls the existing axis-agnostic `Domain.scrollOffsetPinningSystemTop` on the X axis (playing measure span + lookahead measure right edge). Page feeds a new **1-beat** lookahead cursor to the existing cursor→page turn logic. The only new code is a 1-beat anchor (iOS `pageAnchorCursor` computed property / Android `pageAnchorCursor` StateFlow) plus per-mode container/composable wiring. NO new Domain/ssm/JNI symbols — both platforms reuse `scrollOffsetPinningSystemTop` / `nativeScrollOffsetPinningSystemTop`, `cursor(advancedByBeats:)` / `nativeCursorAdvancedByBeats`, `nativeMeasureFrame`, `nativeCursorFrame`, `nativeHorizontalMeasureScrollOffset`.

**Tech Stack:** Swift 6.3 / SwiftUI + UIKit (iOS Reader), Kotlin / Jetpack Compose (Android Reader), Swift Testing, swift-sheet-music via SwiftPM (iOS) + mavenLocal AAR (Android, default `0.0.0-SNAPSHOT` — already has `nativeCursorAdvancedByBeats`).

**Spec:** `docs/superpowers/specs/2026-06-23-reader-horizontal-page-lookahead-design.md`

## Global Constraints

- **No new Domain / ssm / JNI function.** Horizontal reuses `scrollOffsetPinningSystemTop`/`nativeScrollOffsetPinningSystemTop` as-is (vertical-flavored param names; document the axis mapping at the call site). Page reuses `cursor(advancedByBeats:)`/`nativeCursorAdvancedByBeats` with lead `1.0`.
- **Horizontal lead = 2 beats** (reuse existing `scrollAnchorCursor` / `SCROLL_LOOKAHEAD_BEATS = 2.0`). **Page lead = 1 beat** (new `pageLookaheadBeats = 1` / `PAGE_LOOKAHEAD_BEATS = 1.0`).
- **Highlight unchanged** in all modes (stays on the real `displayCursor`).
- **Horizontal Y axis unchanged** (gentle keep-in-view when zoomed); only X gets the lookahead.
- **Page: virtual-cursor-only trigger**; the playhead may briefly trail on the prior page (accepted, by design).
- **Paused / scrubbing / manual seek:** both modes fall back to today's reactive behavior on the real cursor (anchor `nil`).
- **Single repo (Folino).** No ssm change, no ssm push, no AAR republish. Android consumes the existing default-slot ssm AAR.
- **Android cross-compile NOT needed for new symbols** — there are none. The fresh worktree only needs the existing module `.so`/bindings present; copy ALL of them from the primary checkout (per the fresh-worktree-build reference) since this feature changes no Swift JNI.
- **iOS package tests** run via `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` (scheme `Reader`, not `Reader-Package`). American spelling except Apple-API terms; comments reflow at 120 cols.
- **Access modifiers:** keep new members `internal` (no `public`); the lead constants are `static let Double`.

---

## Setup — worktree (once, at execution start)

Use `superpowers:using-git-worktrees`: a **single Folino worktree** off local `main` (which already contains the vertical iOS+Android lookahead + this spec). Symlink `Config/Local.xcconfig`. No ssm worktree (no ssm change). Subagents use the absolute worktree path + `git -C <worktree>` for all git.

> **Execution order:** iOS first (Tasks 1-3, build-verifiable without a device), then Android (Tasks 4-6), then per-platform verification (Tasks 7-8). Tasks 2/3 and 5/6 each consume the anchor from Task 1/4.

---

## Task 1: iOS — `ReaderPlaybackSession.pageAnchorCursor` (1-beat) + test

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/ReaderPlaybackSessionPageAnchorTests.swift`

**Interfaces:**
- Consumes: existing `isPlaying`, `scrubCursor`, `rawPlaybackCursor`, `scoreProvider`, `Score.cursor(advancedByBeats:from:)`; `FakePlaybackController` (`emitIsPlaying`, `emitCursor`).
- Produces: `var pageAnchorCursor: ScoreCursor?` and `static let pageLookaheadBeats: Double` on `ReaderPlaybackSession`. Consumed by Task 3.

- [ ] **Step 1: Write the failing test**

Create `ReaderPlaybackSessionPageAnchorTests.swift` (mirrors `ReaderPlaybackSessionScrollAnchorTests.swift`):

```swift
import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderPlaybackSessionPageAnchorTests {
    private static func twoMeasureScore() -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: [Measure(voices: []), Measure(voices: [])])],
        )
        return Score(division: 480, parts: [part],
                     systemMeasures: [SystemMeasure(), SystemMeasure()], metaTags: [:])
    }

    private static func playingSession(
        _ controller: FakePlaybackController, at cursor: ScoreCursor,
    ) -> ReaderPlaybackSession {
        let score = twoMeasureScore()
        let session = ReaderPlaybackSession(controller: controller, museScoreGeneralProvider: nil)
        session.scoreProvider = { score }
        session.startObservingCursor()
        controller.emitIsPlaying(true)
        controller.emitCursor(cursor)
        return session
    }

    @Test func `page anchor leads the live cursor by one beat while playing`() {
        let controller = FakePlaybackController()
        let session = Self.playingSession(controller, at: .beat(measureIndex: 0, tickInMeasure: 0))
        // 1 beat = 480 ticks into a 1920-tick 4/4 measure.
        #expect(session.pageAnchorCursor == .beat(measureIndex: 0, tickInMeasure: 480))
    }

    @Test func `page anchor is nil when not playing`() {
        let controller = FakePlaybackController()
        let session = Self.playingSession(controller, at: .beat(measureIndex: 0, tickInMeasure: 0))
        controller.emitIsPlaying(false)
        #expect(session.pageAnchorCursor == nil)
    }

    @Test func `page anchor is nil while scrubbing`() {
        let controller = FakePlaybackController()
        let session = Self.playingSession(controller, at: .beat(measureIndex: 0, tickInMeasure: 0))
        session.beginScrub()
        #expect(session.pageAnchorCursor == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

From `Packages/Features/Reader`:
```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/ReaderPlaybackSessionPageAnchorTests
```
Expected: FAIL to compile — `ReaderPlaybackSession` has no member `pageAnchorCursor`.

- [ ] **Step 3: Implement `pageAnchorCursor`**

In `ReaderPlaybackSession.swift`, add right after the existing `scrollAnchorCursor` block + its `scrollLookaheadBeats` constant:

```swift
    /// Lookahead anchor for PAGE mode: the `.beat` cursor `pageLookaheadBeats` beats ahead of the live
    /// position, so the page turns before the playhead reaches the next page. Non-nil ONLY during continuous
    /// playback (not paused / stopped / scrubbing); page mode falls back to `displayCursor` when nil. Never
    /// drives the highlight. Computed from `rawPlaybackCursor` (full-score address); the `.beat` result is
    /// staff-agnostic.
    var pageAnchorCursor: ScoreCursor? {
        guard isPlaying, scrubCursor == nil,
              let raw = rawPlaybackCursor, let score = scoreProvider()
        else { return nil }
        return score.cursor(advancedByBeats: Self.pageLookaheadBeats, from: raw)
    }

    /// Lead for `pageAnchorCursor`, in quarter-note beats. Shorter than `scrollLookaheadBeats` so the playhead
    /// is only briefly on the prior page during an anticipatory page turn.
    static let pageLookaheadBeats: Double = 1
```

- [ ] **Step 4: Run to verify pass**

Same command as Step 2. Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift Packages/Features/Reader/Tests/ReaderTests/ReaderPlaybackSessionPageAnchorTests.swift
git -C <worktree> commit -m "feat(reader): add 1-beat pageAnchorCursor for page-mode lookahead"
```

---

## Task 2: iOS — `HorizontalScoreContainer` lookahead left-align

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalScoreContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` (the `HorizontalScoreContainer(` call, ~lines 200-210)
- Modify: any `HorizontalScoreContainer(` preview/other construction (compiler will flag)

**Interfaces:**
- Consumes: `scrollAnchorCursor` (existing, 2-beat); `Domain.scrollOffsetPinningSystemTop`; the existing `measureRect(for:in:)`, `horizontalMeasureScrollOffset`, `scorePadding`, `viewModel.viewportZoom`.
- Produces: `HorizontalScoreContainer` gains a `let scrollAnchorCursor: ScoreCursor?` parameter.

- [ ] **Step 1: Add the parameter**

In `HorizontalScoreContainer.swift`, immediately after the existing `let playbackCursor: ScoreCursor?` declaration:

```swift
    let playbackCursor: ScoreCursor?
    /// Lookahead anchor (2 beats ahead) used for the X auto-scroll trigger ONLY — never the highlight. `nil`
    /// when not playing, in which case the scroll falls back to the reactive measure keep-in-view.
    let scrollAnchorCursor: ScoreCursor?
```

- [ ] **Step 2: Change the trigger + the X computation**

Replace the `.onChange(of: playbackCursor) { _, newCursor in autoScroll(cursor: newCursor, viewport: viewport) }` (~lines 110-112) with:

```swift
        .onChange(of: [playbackCursor, scrollAnchorCursor]) { _, _ in
            autoScroll(realCursor: playbackCursor, lookaheadCursor: scrollAnchorCursor, viewport: viewport)
        }
```

Then change `autoScroll`'s signature and the X branch. Open the existing `autoScroll(cursor:viewport:)` (~lines 218-262). Rename its parameter to `realCursor` and add a `lookaheadCursor: ScoreCursor?` parameter, and replace the `newX` computation so it pins the playing measure's leading edge with the lookahead trigger when playing, falling back to the existing `horizontalMeasureScrollOffset` when paused. Keep the existing `newY` (keep-in-view) and the `pendingScroll` line unchanged:

```swift
    private func autoScroll(
        realCursor: ScoreCursor?,
        lookaheadCursor: ScoreCursor?,
        viewport: CGSize,
    ) {
        guard let realCursor, let doc = document,
              let rect = doc.cursorFrame(for: realCursor, in: score)
        else { return }

        let zoom = viewModel.viewportZoom
        let pad = 8 * doc.metrics.sp * zoom
        let curX = liveScrollOffset.x

        let newX: CGFloat
        if let lookaheadCursor,
           let realMeasure = measureRect(for: realCursor, in: doc),
           let lookMeasure = measureRect(for: lookaheadCursor, in: doc) {
            // Playback: left-align the playing cursor's MEASURE, re-scrolling only when that measure or the
            // lookahead measure leaves the viewport. Axis-agnostic reuse of `scrollOffsetPinningSystemTop`:
            // the "system" params carry the playing measure's X-span; `lookaheadMax` is the lookahead
            // measure's right edge; `topInset` is the leading pad.
            newX = CGFloat(scrollOffsetPinningSystemTop(
                current: Double(curX),
                systemMin: Double((realMeasure.minX + scorePadding) * zoom),
                systemMax: Double((realMeasure.maxX + scorePadding) * zoom),
                lookaheadMax: Double((lookMeasure.maxX + scorePadding) * zoom),
                viewport: Double(viewport.width),
                topInset: Double(pad),
            ))
        } else if let measure = measureRect(for: realCursor, in: doc) {
            // Paused / scrubbing / manual seek: reactive measure keep-in-view (today's behavior).
            newX = CGFloat(horizontalMeasureScrollOffset(
                current: Double(curX),
                measureMin: Double((measure.minX + scorePadding) * zoom),
                measureMax: Double((measure.maxX + scorePadding) * zoom),
                viewport: Double(viewport.width),
                pad: Double(pad),
            ))
        } else {
            newX = curX
        }

        // (Keep the existing newY keep-in-view computation from the original autoScroll, and the existing
        //  `if abs(...) < 0.5 ...` no-op guard + `pendingScroll = .animated(CGPoint(x: newX, y: newY))`.)
```

(Match the EXACT existing `newY` computation, the no-op threshold guard, and the `pendingScroll` assignment from the current `autoScroll` — only the signature, the `.onChange`, and the `newX` branch change. `cursorFrame(for: realCursor)` is still used as the guard so a stale cursor early-returns.)

- [ ] **Step 3: Wire `scrollAnchorCursor` from `ReaderRootScreen`**

In `ReaderRootScreen.swift`, inside the `HorizontalScoreContainer(` call, immediately after the `playbackCursor: viewModel.playbackSession.displayCursor,` argument, add:

```swift
                        scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
```

- [ ] **Step 4: Fix any other construction sites**

Add `scrollAnchorCursor: nil` to any `HorizontalScoreContainer(` preview/other construction the compiler flags (search with `rg -n "HorizontalScoreContainer\(" Packages/Features/Reader`).

- [ ] **Step 5: Build the Reader package**

From `Packages/Features/Reader`:
```
xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED, `HorizontalScoreContainer.swift` recompiled.

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalScoreContainer.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift
git -C <worktree> commit -m "feat(reader): lookahead left-align the playing measure in horizontal mode"
```

(Stage any preview file you also edited in Step 4.)

---

## Task 3: iOS — `PagedScoreContainer` virtual-cursor page follow

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift` (the `.onChange` trigger, ~lines 198-200)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` (the `PagedScoreContainer(` call, ~lines 211-221)
- Modify: any `PagedScoreContainer(` preview/other construction (compiler will flag)

**Interfaces:**
- Consumes: `pageAnchorCursor` (Task 1); the existing `followCursor(_:)`.
- Produces: `PagedScoreContainer` gains a `let pageAnchorCursor: ScoreCursor?` parameter.

- [ ] **Step 1: Add the parameter**

In `PagedScoreContainer.swift`, immediately after the existing `let playbackCursor: ScoreCursor?` declaration:

```swift
    let playbackCursor: ScoreCursor?
    /// Lookahead anchor (1 beat ahead) used to turn the page early — the page containing this cursor is made
    /// active. `nil` when not playing, in which case page-follow falls back to the real cursor (manual seek).
    let pageAnchorCursor: ScoreCursor?
```

- [ ] **Step 2: Feed the lookahead to `followCursor`**

Replace the `.onChange(of: playbackCursor) { _, newCursor in followCursor(newCursor) }` (~lines 198-200) with:

```swift
        .onChange(of: [playbackCursor, pageAnchorCursor]) { _, _ in
            followCursor(pageAnchorCursor ?? playbackCursor)
        }
```

`followCursor(_:)` is unchanged — it maps the given cursor → measure → system → page range and `commitPageTurn`s. Feeding it the 1-beat lookahead during playback turns to the virtual cursor's page; the real cursor when paused preserves manual-seek behavior.

- [ ] **Step 3: Wire `pageAnchorCursor` from `ReaderRootScreen`**

In `ReaderRootScreen.swift`, inside the `PagedScoreContainer(` call, immediately after `playbackCursor: viewModel.playbackSession.displayCursor,`, add:

```swift
                        pageAnchorCursor: viewModel.playbackSession.pageAnchorCursor,
```

- [ ] **Step 4: Fix any other construction sites**

Add `pageAnchorCursor: nil` to any `PagedScoreContainer(` preview/other construction the compiler flags (search with `rg -n "PagedScoreContainer\(" Packages/Features/Reader`).

- [ ] **Step 5: Build the Reader package**

From `Packages/Features/Reader`:
```
xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED, `PagedScoreContainer.swift` recompiled.

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift
git -C <worktree> commit -m "feat(reader): turn pages to the 1-beat lookahead cursor in page mode"
```

(Stage any preview file you also edited in Step 4.)

---

## Task 4: Android — `ReaderAudioViewModel.pageAnchorCursor` StateFlow (1-beat)

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt`

**Interfaces:**
- Consumes: the existing `scrollAnchorCursor` derivation pattern (lines ~90-105), `SheetMusicJNI.nativeCursorAdvancedByBeats`, `ScoreCursorCodec`.
- Produces: `val pageAnchorCursor: StateFlow<ScoreCursor?>` + companion `const val PAGE_LOOKAHEAD_BEATS = 1.0`. Consumed by Task 6.

- [ ] **Step 1: Add the 1-beat anchor flow**

Add to `ReaderAudioViewModel`, mirroring the existing `scrollAnchorCursor` (just a different lead constant):

```kotlin
/**
 * Lookahead anchor for PAGE mode: the cursor [PAGE_LOOKAHEAD_BEATS] beats ahead of the live cursor,
 * via the shared ssm `Score.cursor(advancedByBeats:from:)` (JNI). Non-null ONLY while playing; page mode
 * falls back to the real cursor when null. Mirrors iOS `ReaderPlaybackSession.pageAnchorCursor`.
 */
val pageAnchorCursor: StateFlow<ScoreCursor?> =
    _engine.flatMapLatest { engine ->
        if (engine == null) flowOf(null)
        else combine(engine.state, engine.currentCursor) { state, cursor ->
            val handle = scoreHandle
            if (state != PlaybackState.PLAYING || cursor == null || handle == null) {
                null
            } else {
                ScoreCursorCodec.decode(
                    SheetMusicJNI.nativeCursorAdvancedByBeats(
                        handle, ScoreCursorCodec.encode(cursor), PAGE_LOOKAHEAD_BEATS,
                    ),
                )
            }
        }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)
```

In the same `companion object` as `SCROLL_LOOKAHEAD_BEATS`:

```kotlin
const val PAGE_LOOKAHEAD_BEATS = 1.0
```

(Match the EXACT engine/flow/`scoreHandle` names already used by `scrollAnchorCursor` in this file.)

- [ ] **Step 2: Compile the Reader Android module**

From the worktree root (the existing module `.so`/bindings must be staged — see Task 8 Step 1; for a compile-only check the ssm AAR + Reader `.so` from primary suffice):
```
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin --no-daemon
```
Expected: `BUILD SUCCESSFUL`. (`nativeCursorAdvancedByBeats` resolves from the default-slot ssm AAR `0.0.0-SNAPSHOT`.)

- [ ] **Step 3: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt
git -C <worktree> commit -m "feat(android-reader): add 1-beat pageAnchorCursor flow"
```

---

## Task 5: Android — `HorizontalScore` lookahead left-align

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (the `HorizontalScore` auto-scroll `LaunchedEffect`, ~lines 1304-1347)

**Interfaces:**
- Consumes: `audioVm.scrollAnchorCursor` (2-beat, existing); `SheetMusicJNI.nativeMeasureFrame`; `FolinoReaderJNI.nativeScrollOffsetPinningSystemTop` (existing) + `nativeHorizontalMeasureScrollOffset`; existing `padPx`, `fitPxPerMM`, `scale`, `hScroll`, `viewportSize`.

- [ ] **Step 1: Combine the lookahead into the horizontal auto-scroll**

In `HorizontalScore`'s auto-scroll `LaunchedEffect`, combine `audioVm.currentCursor` with `audioVm.scrollAnchorCursor`; when the anchor is non-null, pin the playing measure's leading edge via the lookahead, else keep the existing `nativeHorizontalMeasureScrollOffset`. Preserve the existing vertical-when-zoomed block. Match the file's exact frame field names + Float/Double conversions:

```kotlin
combine(audioVm.currentCursor, audioVm.scrollAnchorCursor) { real, anchor -> real to anchor }
    .collectLatest { (real, anchor) ->
        if (real == null) return@collectLatest
        val realMBytes = SheetMusicJNI.nativeMeasureFrame(handle, ScoreCursorCodec.encode(real))
        if (realMBytes.isNotEmpty()) {
            val rm = DecodedFrameCodec.decode(realMBytes)
            val realXMin = (rm.x * fitPxPerMM * scale).toDouble()
            val realXMax = ((rm.x + rm.width) * fitPxPerMM * scale).toDouble()
            val newX = if (anchor != null) {
                val lookMBytes = SheetMusicJNI.nativeMeasureFrame(handle, ScoreCursorCodec.encode(anchor))
                val lookXMax = if (lookMBytes.isNotEmpty()) {
                    val lm = DecodedFrameCodec.decode(lookMBytes)
                    ((lm.x + lm.width) * fitPxPerMM * scale).toDouble()
                } else {
                    realXMax
                }
                // Axis-agnostic reuse: "system" params carry the playing measure's X-span; topInset = padPx.
                FolinoReaderJNI.nativeScrollOffsetPinningSystemTop(
                    hScroll.value.toDouble(), realXMin, realXMax, lookXMax,
                    viewportSize.width.toDouble(), padPx.toDouble(),
                ).toFloat()
            } else {
                FolinoReaderJNI.nativeHorizontalMeasureScrollOffset(
                    hScroll.value.toDouble(), realXMin, realXMax,
                    viewportSize.width.toDouble(), padPx.toDouble(),
                ).toFloat()
            }
            if (abs(newX - hScroll.value) >= 0.5f) {
                hScroll.animateScrollTo(newX.toInt().coerceAtLeast(0))
            }
        }
        // (Keep the existing vertical-scroll-when-zoomed block below, following `real`.)
    }
```

(Open the current `LaunchedEffect` first and preserve the vertical block + the exact surrounding code. `import kotlinx.coroutines.flow.combine` if not already imported.)

- [ ] **Step 2: Compile**

```
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin --no-daemon
```
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git -C <worktree> commit -m "feat(android-reader): lookahead left-align the playing measure in horizontal mode"
```

---

## Task 6: Android — `PagedScore` virtual-cursor page follow

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt` (the page-turn `LaunchedEffect`, ~lines 127-147)

**Interfaces:**
- Consumes: `audioVm.pageAnchorCursor` (Task 4); the existing `nativeCursorFrame` → `breaksMm` band search → `pagerState.animateScrollToPage`.

- [ ] **Step 1: Source the page-turn cursor from the 1-beat anchor**

In `PagedScore.kt`'s page-turn `LaunchedEffect`, replace the bare `audioVm.currentCursor` source with `pageAnchorCursor ?? currentCursor` so playback turns to the virtual cursor's page and paused turns to the real cursor. Keep the `nativeCursorFrame` → `breaksMm` band search → `distinctUntilChanged` → `animateScrollToPage` pipeline unchanged:

```kotlin
combine(audioVm.currentCursor, audioVm.pageAnchorCursor) { real, anchor -> anchor ?: real }
    .mapNotNull { cursor ->
        if (cursor == null) return@mapNotNull null
        val bytes = SheetMusicJNI.nativeCursorFrame(h, ScoreCursorCodec.encode(cursor))
        if (bytes.isEmpty()) return@mapNotNull null
        val yMm = DecodedFrameCodec.decode(bytes).y.toDouble()
        var target = 0
        for (i in 0 until breaksMm.size - 1) {
            if (yMm >= breaksMm[i] && yMm < breaksMm[i + 1]) { target = i; break }
            if (i == breaksMm.size - 2) target = i
        }
        target
    }
    .distinctUntilChanged()
    .collectLatest { target ->
        if (target != pagerState.currentPage) pagerState.animateScrollToPage(target)
    }
```

(Open the current `LaunchedEffect` first and match the exact `h`/`breaksMm`/`pagerState` names + the existing band-search body. `import kotlinx.coroutines.flow.combine` if needed.)

- [ ] **Step 2: Compile**

```
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin --no-daemon
```
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt
git -C <worktree> commit -m "feat(android-reader): turn pages to the 1-beat lookahead cursor in page mode"
```

---

## Task 7: iOS integration build + test

**Files:** none (verification).

- [ ] **Step 1: Build the iOS app**

From the worktree root:
```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```
(Run `xcodegen generate` first if `Folino.xcodeproj` is absent in the fresh worktree.) Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Run the Reader test target**

From `Packages/Features/Reader`:
```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: PASS, including `ReaderPlaybackSessionPageAnchorTests` (3 tests) and no regression in the existing suites.

- [ ] **Step 3: Hand off iOS manual verification**

Per project policy (no simulator gesture-driving), ask the user to clean-build on device and confirm: **horizontal** — the playing measure left-aligns ~2 beats early; **page** — the page turns ~1 beat before the playhead reaches it (highlight briefly trails); paused/scrub unchanged; vertical unchanged.

---

## Task 8: Android integration build + on-device verify

**Files:** none (verification). Requires the user's connected device/emulator.

- [ ] **Step 1: Stage the unchanged modules' `.so`/bindings from primary**

This feature adds NO new JNI symbols, so the fresh worktree needs only the EXISTING `.so`/bindings. Copy ALL four Android modules' artifacts from the primary checkout (Reader included — its FolinoReaderJNI is unchanged this feature):

```
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoReaderAndroid/src/main/jniLibs <worktree>/Android/FolinoReaderAndroid/src/main/
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoReaderAndroid/src/main/java-generated <worktree>/Android/FolinoReaderAndroid/src/main/
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoSettingsAndroid/src/main/jniLibs <worktree>/Android/FolinoSettingsAndroid/src/main/
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoSettingsAndroid/src/main/java-generated <worktree>/Android/FolinoSettingsAndroid/src/main/
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoLibraryAndroid/src/main/jniLibs <worktree>/Android/FolinoLibraryAndroid/src/main/
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoSoundfontAndroid/src/main/jniLibs <worktree>/Android/FolinoSoundfontAndroid/src/main/
```

(`jniLibs`/`java-generated` are gitignored — not committed. Library/Soundfont `java-generated` is gradle-wirelet-generated at build, so only their `jniLibs` are copied.)

- [ ] **Step 2: Build + install on the device**

Confirm a device: `adb devices`. Then (use the real-device serial or `emulator-5554`, per how the user has it connected; do not disconnect a Pixel without being asked):
```
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH ANDROID_SERIAL=<serial> Android/gradlew -p Android :app:installDebug --no-daemon
```
Expected: BUILD SUCCESSFUL + installed. (Default `ssmVersion=0.0.0-SNAPSHOT` already carries `nativeCursorAdvancedByBeats`.)

- [ ] **Step 3: Launch + crash-check**

```
ANDROID_SERIAL=<serial> adb logcat -c
ANDROID_SERIAL=<serial> adb shell am start -n com.harmolo.folino/com.keynumber.folino.MainActivity
ANDROID_SERIAL=<serial> adb logcat -d -t 400 | rg -i "UnsatisfiedLinkError|FATAL EXCEPTION|WireFormat" || echo "clean"
```
Expected: clean launch, app pid running.

- [ ] **Step 4: Hand off Android manual verification**

Ask the user to confirm on device: **horizontal** — the playing measure left-aligns ~2 beats early; **page** — the page turns ~1 beat before the playhead reaches it (highlight briefly trails); paused/swipe unchanged; vertical unchanged.

---

## Self-Review

- **Spec coverage:** iOS pageAnchorCursor 1-beat (Task 1) ✓; iOS horizontal 2-beat left-align via `scrollOffsetPinningSystemTop` (Task 2) ✓; iOS page virtual-follow (Task 3) ✓; Android pageAnchorCursor (Task 4) ✓; Android horizontal (Task 5) ✓; Android page (Task 6) ✓; root wiring (Tasks 2,3) ✓; highlight unchanged / Y unchanged / paused fallback (Tasks 2,3,5,6) ✓; no new Domain/ssm/JNI (reuse throughout) ✓; parity (same design both platforms) ✓; verification (Tasks 7,8) ✓.
- **Placeholder scan:** none — code/commands complete with expected output. The "match the exact existing names / preserve the existing newY+vertical block" notes are adaptation guidance for code this plan can't fully reproduce from outside the files, not deferred work; signatures and the new branches are fully specified.
- **Type consistency:** `pageAnchorCursor: ScoreCursor?` + `pageLookaheadBeats`/`PAGE_LOOKAHEAD_BEATS = 1.0` consistent across Tasks 1,3,4,6; `scrollOffsetPinningSystemTop`/`nativeScrollOffsetPinningSystemTop` 6-arg signature matches the shipped vertical function; `HorizontalScoreContainer.scrollAnchorCursor` / `PagedScoreContainer.pageAnchorCursor` params match their `ReaderRootScreen` call sites.
- **Note:** exact iOS `newY`/no-op-guard lines in `HorizontalScoreContainer.autoScroll`, the Android `HorizontalScore` vertical block, and the Android `PagedScore` band-search body are taken from the exploration but must be matched against the real files during implementation — each task says so where it matters.
