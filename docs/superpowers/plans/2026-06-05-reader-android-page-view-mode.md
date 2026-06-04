# Android Reader Page View Mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a page-by-page view mode to the Android Reader at parity with iOS page mode, paginating the existing tall layout by viewport height and navigating with swipe + tap zones + playback-cursor auto page-turn.

**Architecture:** A new Foundation-only `ScorePaginator` in `swift-sheet-music`'s `SheetMusicLayout` computes system-aligned page breaks; a new `nativePageBreaks` JNI returns them (mm) to Kotlin. The Android `PagedScore` composable renders the existing tall `ScorePage` clipped to each page's band inside a `HorizontalPager`, with a 4-zone tap overlay and cursor-driven auto page-turn. The `when(layoutMode) { PAGE -> … }` branch point already exists (commit `3bcc8a0`).

**Tech Stack:** Swift 6 (SheetMusicLayout, SheetMusicAndroidJNI, swift-java/jextract), Kotlin + Jetpack Compose (Material3, `androidx.compose.foundation.pager`), DataStore.

**Spec:** `docs/superpowers/specs/2026-06-05-reader-android-page-view-mode-design.md`

---

## Conventions & Constraints (read first)

- **Two repos, both edited in worktrees.** `swift-sheet-music` lives at `~/Developer/Personal/swift-packages/swift-sheet-music`; create a worktree off its local `main` (which carries the bounded-scroll fix — NOT the `chore/ci-manual-only-preflight` branch). Folino work uses a Folino worktree.
- **ssm test block:** the single `Tests/SheetMusicTests` target pulls in JNI/jextract deps, so `swift test` for the whole target can fail to build on host. For the pure paginator, run `xcrun swift test --filter ScorePaginatorTests` from the ssm package; if the target won't build on host, fall back to the host-buildable verification in Task 1 Step 6 (a throwaway `swift` snippet against the same inputs). Individual targets are otherwise verified with `xcrun swift build`.
- **No GPL deps, no new SwiftPM deps.** Pure additions to existing targets only.
- **Endianness:** the `nativePageBreaks` wire format defined here is **big-endian** on both sides (Swift writes big-endian; Kotlin reads with `ByteBuffer` default order). Both encode and decode are defined in this plan — do not assume any other codec's convention.
- **Commit frequently**, one logical change per commit. Each repo commits independently.

---

## File Structure

**swift-sheet-music:**
- Create: `Sources/SheetMusicLayout/Layout/ScorePaginator.swift` — shared system-aligned paginator.
- Create: `Tests/SheetMusicTests/ScorePaginatorTests.swift` — paginator unit tests.
- Modify: `Sources/SheetMusicAndroidJNI/JNISymbols.swift` — add `nativePageBreaks`.
- Create: `Sources/SheetMusicAndroidJNI/PageBreaksWire.swift` — big-endian encode helper.

**Folino:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift` — delegate to `ScorePaginator` (iOS parity; behavior unchanged). *(Review-flagged: touches iOS Reader.)*
- Create: `Android/FolinoReaderAndroid/.../reader/PageBreaksCodec.kt` — Kotlin big-endian decoder.
- Create: `Android/FolinoReaderAndroid/.../reader/PagedScore.kt` — paged surface (render + pager + pinch).
- Create: `Android/FolinoReaderAndroid/.../reader/PageTapOverlay.kt` — 4-zone tap overlay + badge + hint.
- Modify: `Android/FolinoReaderAndroid/.../reader/ReaderViewModel.kt` — expose `pageBreaksMm` + recompute.
- Modify: `Android/FolinoReaderAndroid/.../reader/ReaderScreen.kt` — `PAGE` branch → `PagedScore`; accept `pageTapHintDismissed` + `onDismissPageTapHint`.
- Modify: `Android/app/.../ui/settings/SettingsPrefs.kt` — add `pageTapHintDismissed` key.
- Modify: `Android/app/.../MainActivity.kt` — thread the hint pref into `ReaderScreen`.

---

## PHASE 0 — swift-sheet-music worktree

- [ ] **Step 1: Create the ssm worktree off local main**

```bash
cd ~/Developer/Personal/swift-packages/swift-sheet-music
git worktree add -b page-breaks ../swift-sheet-music-page-breaks main
```

Expected: a new worktree at `../swift-sheet-music-page-breaks` on branch `page-breaks`. All subsequent ssm paths below are relative to that worktree.

---

## Task 1: `ScorePaginator` in SheetMusicLayout

**Files:**
- Create: `Sources/SheetMusicLayout/Layout/ScorePaginator.swift`
- Test: `Tests/SheetMusicTests/ScorePaginatorTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/SheetMusicTests/ScorePaginatorTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import SheetMusicLayout

@Suite struct ScorePaginatorTests {
    /// Build a system whose origin.y / height let us drive pagination by Y only.
    /// `pageBreak` marks the last measure's authored `<LayoutBreak>page`.
    private func system(y: CGFloat, height: CGFloat, pageBreak: Bool = false) -> LayoutSystem {
        LayoutSystem.testStub(originY: y, height: height, lastMeasurePageBreak: pageBreak)
    }

    @Test func emptyYieldsNoPages() {
        #expect(ScorePaginator.paginate(systems: [], pageHeight: 100, policy: .ignoreAll).isEmpty)
    }

    @Test func everySystemFitsOnePage() {
        let systems = [system(y: 0, height: 40), system(y: 40, height: 40)]
        let pages = ScorePaginator.paginate(systems: systems, pageHeight: 1000, policy: .ignoreAll)
        #expect(pages == [0 ..< 2])
    }

    @Test func overflowStartsNewPageAtSystemBoundary() {
        // pageHeight 100: system0 [0,60), system1 [60,120) overflows (120 > 100) → new page.
        let systems = [system(y: 0, height: 60), system(y: 60, height: 60), system(y: 120, height: 60)]
        let pages = ScorePaginator.paginate(systems: systems, pageHeight: 100, policy: .ignoreAll)
        #expect(pages == [0 ..< 1, 1 ..< 2, 2 ..< 3])
    }

    @Test func authoredPageBreakClosesPageUnderHonor() {
        let systems = [system(y: 0, height: 30, pageBreak: true), system(y: 30, height: 30)]
        let pages = ScorePaginator.paginate(systems: systems, pageHeight: 1000, policy: .honor)
        #expect(pages == [0 ..< 1, 1 ..< 2])
    }

    @Test func ignoreAllIgnoresAuthoredPageBreak() {
        let systems = [system(y: 0, height: 30, pageBreak: true), system(y: 30, height: 30)]
        let pages = ScorePaginator.paginate(systems: systems, pageHeight: 1000, policy: .ignoreAll)
        #expect(pages == [0 ..< 2])
    }
}
```

> If `LayoutSystem` has no ergonomic memberwise init for a stub, add a `#if DEBUG` test helper `LayoutSystem.testStub(originY:height:lastMeasurePageBreak:)` in the test file's `@testable` scope or in a small test-support extension. Inspect `Sources/SheetMusicLayout/Layout/LayoutSystem.swift` and `LayoutMeasure.swift` for the real initializers and mirror them; the stub only needs `origin`, `size`, and `measures.last?.pageBreak`.

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcrun swift test --package-path ~/Developer/Personal/swift-packages/swift-sheet-music-page-breaks --filter ScorePaginatorTests
```

Expected: FAIL — `ScorePaginator` is undefined. (If the SheetMusicTests target cannot build on host due to JNI deps, see the Conventions note and use the Step 6 fallback to drive Steps 3–5.)

- [ ] **Step 3: Write `ScorePaginator`**

`Sources/SheetMusicLayout/Layout/ScorePaginator.swift`:

```swift
import CoreGraphics

/// Shared, Foundation-only paginator used by the Android JNI bridge, the iOS
/// paged Reader, and (optionally) `SheetMusicUI.PagedScoreView`. Walks `systems`
/// in document-Y order and closes the current page just before a system whose
/// bottom edge would extend past `pageTopDoc + pageHeight`. `pageTopDoc` is 0 for
/// the first page (so the title / pre-system gap renders there) and the previous
/// page's last-system bottom for every subsequent page. An authored
/// `<LayoutBreak>page` on a system's last measure closes the page immediately
/// unless `policy == .ignoreAll`.
public enum ScorePaginator {
    public static func paginate(
        systems: [LayoutSystem],
        pageHeight: CGFloat,
        policy: LayoutBreakPolicy,
    ) -> [Range<Int>] {
        guard !systems.isEmpty, pageHeight > 0 else { return [] }
        var pages: [Range<Int>] = []
        var pageStart = 0
        var pageTopDoc: CGFloat = 0

        for (index, system) in systems.enumerated() {
            let systemBottom = system.origin.y + system.size.height
            if index > pageStart, systemBottom - pageTopDoc > pageHeight {
                pages.append(pageStart ..< index)
                pageStart = index
                pageTopDoc = systems[index - 1].origin.y + systems[index - 1].size.height
            }
            if policy != .ignoreAll, system.measures.last?.pageBreak == true {
                pages.append(pageStart ..< (index + 1))
                pageStart = index + 1
                pageTopDoc = systemBottom
            }
        }
        if pageStart < systems.count {
            pages.append(pageStart ..< systems.count)
        }
        return pages
    }

    /// Document-Y breakpoints (the value rendered/consumed downstream), derived
    /// from `paginate`. Returns `[0, top₁, top₂, …, contentBottom]`, length
    /// `pages.count + 1`. Empty for an empty/zero-height input.
    public static func pageBreakOffsets(
        systems: [LayoutSystem],
        pageHeight: CGFloat,
        policy: LayoutBreakPolicy,
    ) -> [CGFloat] {
        let pages = paginate(systems: systems, pageHeight: pageHeight, policy: policy)
        guard !pages.isEmpty else { return [] }
        var offsets: [CGFloat] = [0]
        for page in pages.dropFirst() {
            let prevLast = systems[page.lowerBound - 1]
            offsets.append(prevLast.origin.y + prevLast.size.height)
        }
        let last = systems[systems.count - 1]
        offsets.append(last.origin.y + last.size.height)
        return offsets
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcrun swift test --package-path ~/Developer/Personal/swift-packages/swift-sheet-music-page-breaks --filter ScorePaginatorTests
```

Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git -C ~/Developer/Personal/swift-packages/swift-sheet-music-page-breaks add Sources/SheetMusicLayout/Layout/ScorePaginator.swift Tests/SheetMusicTests/ScorePaginatorTests.swift
git -C ~/Developer/Personal/swift-packages/swift-sheet-music-page-breaks commit -m "feat(layout): shared ScorePaginator (system-aligned page breaks)"
```

- [ ] **Step 6: (Fallback only) host-buildable verification if the test target won't build**

If `swift test` cannot build the SheetMusicTests target on host, verify the target compiles in isolation and exercise the function from a scratch file:

```bash
xcrun swift build --package-path ~/Developer/Personal/swift-packages/swift-sheet-music-page-breaks --target SheetMusicLayout
```

Expected: build succeeds. Then sanity-check `pageBreakOffsets`/`paginate` logic against the Step-1 cases by reasoning through them (the algorithm is copied verbatim from the already-shipping iOS `PagedScoreContainer.paginate`). Record in the commit body that host tests were blocked.

---

## Task 2: iOS Reader delegates to `ScorePaginator` (parity, review-flagged)

> **Review flag:** this edits iOS Reader code. The algorithm is identical, so behavior is unchanged; it removes the duplicate so iOS and Android share one paginator. Surface this in review before merging the Folino side.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift` (the `static func paginate` at lines ~280-310)

- [ ] **Step 1: Replace the private paginator body with a delegation**

In `PagedScoreContainer.swift`, replace the entire `static func paginate(systems:pageHeight:policy:) -> [Range<Int>]` implementation with:

```swift
static func paginate(
    systems: [LayoutSystem],
    pageHeight: CGFloat,
    policy: LayoutBreakPolicy,
) -> [Range<Int>] {
    ScorePaginator.paginate(systems: systems, pageHeight: pageHeight, policy: policy)
}
```

(Keep the call sites unchanged; `ScorePaginator` is in `SheetMusicLayout`, already imported by this file.)

- [ ] **Step 2: Build the Reader package (iOS) to verify**

```bash
cd ~/Developer/Personal/ios-apps/Folino-iOS  # primary or Folino worktree, once ssm is re-pinned (Task 5)
```

> This task compiles only after the Folino side is re-pinned to the new ssm commit (Task 5). Sequence it after Task 5 in execution, but keep it here logically. Build via the project's Reader scheme:
> `xcodebuild -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build`
> Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit (Folino side, after re-pin)**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift
git commit -m "refactor(reader): delegate page pagination to shared ScorePaginator"
```

---

## Task 3: `nativePageBreaks` JNI + wire encode

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/PageBreaksWire.swift`
- Modify: `Sources/SheetMusicAndroidJNI/JNISymbols.swift`

- [ ] **Step 1: Write the big-endian encoder**

`Sources/SheetMusicAndroidJNI/PageBreaksWire.swift`:

```swift
import Foundation

/// Wire format for `nativePageBreaks`: `i32 count` followed by `count × f64`,
/// all **big-endian**. Decoded by Kotlin `PageBreaksCodec`.
enum PageBreaksWire {
    static func encode(_ offsetsMm: [Double]) -> Data {
        var data = Data()
        var count = UInt32(offsetsMm.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for value in offsetsMm {
            var bits = value.bitPattern.bigEndian // UInt64 big-endian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }
}
```

- [ ] **Step 2: Add the JNI symbol**

Append to `Sources/SheetMusicAndroidJNI/JNISymbols.swift`:

```swift
// MARK: - Pagination (swift-java entry point)

/// JNI entry point for the Kotlin `SheetMusicJNI.nativePageBreaks(...)` call site.
/// Paginates the cached layout document by `pageHeightMM` and returns the
/// document-Y page break offsets in **mm**, encoded by `PageBreaksWire`
/// (`[0, top₁, …, contentBottom]`, length = pageCount + 1). Returns empty `Data`
/// when the handle is unknown or the document has no systems.
public func nativePageBreaks(scoreHandle: Int64, pageHeightMM: Double) -> Data {
    guard let document = LayoutDocumentCache.document(for: scoreHandle) else { return Data() }
    let mmToPt = 72.0 / 25.4
    let pageHeightPt = CGFloat(pageHeightMM * mmToPt)
    let offsetsPt = ScorePaginator.pageBreakOffsets(
        systems: document.systems,
        pageHeight: pageHeightPt,
        policy: .honor,
    )
    guard !offsetsPt.isEmpty else { return Data() }
    let offsetsMm = offsetsPt.map { Double($0) / mmToPt }
    return PageBreaksWire.encode(offsetsMm)
}
```

> Verify the `LayoutDocumentCache` accessor name in `Sources/SheetMusicAndroidJNI/LayoutCache.swift` (the existing `nativeCursorFrame` reads it). Use the same getter; the `document(for:)` name above is a placeholder for whatever that file exposes — match the real symbol. Use `import SheetMusicLayout` / `CoreGraphics` as the file already does.

- [ ] **Step 3: Build the JNI target (host) to verify it compiles**

```bash
xcrun swift build --package-path ~/Developer/Personal/swift-packages/swift-sheet-music-page-breaks --target SheetMusicAndroidJNI
```

Expected: BUILD SUCCEEDED. (Pure compile check; the symbol runs only on-device.)

- [ ] **Step 4: Commit**

```bash
git -C ~/Developer/Personal/swift-packages/swift-sheet-music-page-breaks add Sources/SheetMusicAndroidJNI/PageBreaksWire.swift Sources/SheetMusicAndroidJNI/JNISymbols.swift
git -C ~/Developer/Personal/swift-packages/swift-sheet-music-page-breaks commit -m "feat(android-jni): nativePageBreaks returns mm page-break offsets"
```

- [ ] **Step 5: Record the ssm commit for the Folino re-pin**

```bash
git -C ~/Developer/Personal/swift-packages/swift-sheet-music-page-breaks rev-parse HEAD
```

Note this hash; it is the pin used in Task 5. (Push to origin only if/when the user approves; local pinning works via `Package.resolved` against the local commit during development per existing project flow.)

---

## PHASE 1 — Folino worktree

- [ ] **Task 4: Create the Folino worktree and link Local.xcconfig**

```bash
# From the Folino primary checkout (EnterWorktree handles base = local main HEAD):
# create worktree "reader-android-page-mode-impl"
ln -sf ../../../Config/Local.xcconfig <worktree>/Config/Local.xcconfig
```

> Use the session's worktree tooling to branch off local `main` (which now includes the spec + wiring). Symlink `Config/Local.xcconfig` from the primary so xcodegen doesn't re-prompt for the Team ID.

---

## Task 5: Re-pin ssm + rebuild Reader native libs

**Files:**
- Modify: `Package.resolved` files / `Packages/Features/Reader/Package.swift` `swift-sheet-music` pin (and any other consumer pins), per the project's existing pin flow.

- [ ] **Step 1: Point the Reader package at the new ssm commit**

Update the `swift-sheet-music` dependency in `Packages/Features/Reader/Package.swift` (and the matching `Package.resolved`) to the commit from Task 3 Step 5. Follow the existing local-pin approach used in prior Android tasks (branch/revision pin).

- [ ] **Step 2: Resolve + rebuild the Reader `.so` and Java bindings**

```bash
# From the Folino worktree, using the documented Android toolchain PATH:
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH \
  <worktree>/Scripts/android-build-reader-libs.sh
```

Expected: `libFolinoReaderJNI.so` rebuilt for `arm64-v8a` + `x86_64`, staged into `Android/FolinoReaderAndroid/src/main/jniLibs/`, and jextract Java bindings into `src/main/java-generated/` (now including `nativePageBreaks`).

- [ ] **Step 3: Verify the new symbol is in the bindings**

```bash
grep -r "nativePageBreaks" <worktree>/Android/FolinoReaderAndroid/src/main/java-generated/
```

Expected: at least one match (the generated `SheetMusicJNI` / `FolinoReaderJNI` binding). If absent, re-check the WireletObservableBridges scanner pitfall (non-attribute lines between attribute and declaration drop symbols) and the `.so` rebuild.

- [ ] **Step 4: Commit the pin + regenerated bindings**

```bash
git add Packages/Features/Reader/Package.swift Packages/Features/Reader/Package.resolved
git commit -m "build(android): re-pin swift-sheet-music for nativePageBreaks"
```

> `jniLibs/` and `java-generated/` are gitignored; only the pin + resolved files are committed.

---

## Task 6: Kotlin page-breaks decode + ViewModel state

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PageBreaksCodec.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt`

- [ ] **Step 1: Write the decoder**

`PageBreaksCodec.kt`:

```kotlin
package com.keynumber.folino.reader

import java.nio.ByteBuffer

/**
 * Decodes the `nativePageBreaks` wire format: big-endian `i32 count` followed by
 * `count × f64` (document-Y page break offsets, mm). `ByteBuffer` defaults to
 * big-endian, matching the Swift `PageBreaksWire` encoder.
 */
object PageBreaksCodec {
    fun decode(bytes: ByteArray): DoubleArray {
        if (bytes.size < 4) return DoubleArray(0)
        val buf = ByteBuffer.wrap(bytes)
        val count = buf.int
        if (count < 0 || bytes.size < 4 + count * 8) return DoubleArray(0)
        return DoubleArray(count) { buf.double }
    }
}
```

- [ ] **Step 2: Expose page breaks on the ViewModel**

In `ReaderViewModel.kt`, add a suspend helper that calls the JNI (the layout is already cached by `nativeComputeLayout` during `load`). Page height in mm is supplied by the UI (viewport-derived), so the call is parameterized:

```kotlin
/** Page-break offsets (document-Y, mm) for the cached layout at the given page height. */
suspend fun pageBreaks(pageHeightMm: Double): DoubleArray {
    val h = handle ?: return DoubleArray(0)
    val bytes = withContext(Dispatchers.Default) {
        SheetMusicJNI.nativePageBreaks(h.raw, pageHeightMm)
    }
    return PageBreaksCodec.decode(bytes)
}
```

> Confirm the generated binding class/method name from Task 5 Step 3 (it may be `SheetMusicJNI.nativePageBreaks` or under `FolinoReaderJNI`). Use the real name. `withContext`/`Dispatchers` are already imported in this file.

- [ ] **Step 3: Compile-check the Reader module**

```bash
<worktree>/Android/gradlew -p <worktree>/Android :FolinoReaderAndroid:compileDebugKotlin --no-daemon
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PageBreaksCodec.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt
git commit -m "feat(reader-android): decode page-break offsets over JNI"
```

---

## Task 7: `PagedScore` composable (band-clip render + pager + pinch)

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt`

- [ ] **Step 1: Write the paged surface**

`PagedScore.kt` (render one page band per pager page; swipe enabled only at unit zoom; pinch + pan within a page mirrors `ReadyScore`):

```kotlin
package com.keynumber.folino.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntSize
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.render.FontProvider
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage

@Composable
fun PagedScore(
    state: ReaderState.Ready,
    scoreHandle: Long?,
    fontProvider: FontProvider,
    audioVm: ReaderAudioViewModel,
    readerVm: ReaderViewModel,
    pageTapHintDismissed: Boolean,
    onDismissPageTapHint: () -> Unit,
) {
    val page = state.program.pages.first()
    val density = LocalDensity.current

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    var breaksMm by remember { mutableStateOf(DoubleArray(0)) }
    var scale by remember { mutableFloatStateOf(1f) }

    val fitPxPerMM = if (page.widthMM > 0 && viewportSize.width > 0) {
        (viewportSize.width / page.widthMM).toFloat()
    } else 0f

    // Recompute page breaks whenever the page height (mm) the viewport represents changes.
    val viewportHeightMm = if (fitPxPerMM > 0f) viewportSize.height / fitPxPerMM else 0.0
    LaunchedEffect(scoreHandle, viewportHeightMm) {
        if (scoreHandle != null && viewportHeightMm > 0.0) {
            breaksMm = readerVm.pageBreaks(viewportHeightMm)
        }
    }

    val pageCount = (breaksMm.size - 1).coerceAtLeast(0)
    val pagerState = rememberPagerState(pageCount = { pageCount })

    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged { viewportSize = it },
        contentAlignment = Alignment.TopStart,
    ) {
        if (pageCount == 0) return@Box

        HorizontalPager(
            state = pagerState,
            userScrollEnabled = scale == 1f, // swipe only at unit zoom (iOS parity)
            modifier = Modifier.fillMaxSize(),
        ) { pageIndex ->
            val topMm = breaksMm[pageIndex]
            val bottomMm = breaksMm[pageIndex + 1]
            val bandHeightPx = ((bottomMm - topMm).toFloat() * fitPxPerMM * scale)
            val topOffsetPx = (topMm.toFloat() * fitPxPerMM * scale)
            val contentWidthPx = page.widthMM.toFloat() * fitPxPerMM * scale

            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.White)
                    .clipToBounds(),
                contentAlignment = Alignment.TopStart,
            ) {
                // Render the full tall surface, translated up so this page's band
                // sits at the top; clipToBounds above hides the rest. Band boundaries
                // are system-aligned, so no neighbouring system leaks in.
                Box(
                    Modifier
                        .size(
                            width = with(density) { contentWidthPx.toDp() },
                            height = with(density) { bandHeightPx.toDp() },
                        )
                        .clipToBounds(),
                ) {
                    Box(Modifier.graphicsLayer { translationY = -topOffsetPx }) {
                        ScorePage(
                            page = page,
                            fontProvider = fontProvider,
                            pxPerMM = fitPxPerMM * scale,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        scoreHandle?.let { h ->
                            PlaybackCursorOverlay(
                                scoreHandle = h,
                                cursorFlow = audioVm.currentCursor,
                                pxPerMM = fitPxPerMM,
                                scale = scale,
                                panOffset = Offset.Zero,
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                    }
                }
            }
        }

        // Pinch zoom: two-finger only; single-finger falls through to the pager.
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(fitPxPerMM) {
                    if (fitPxPerMM <= 0f) return@pointerInput
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        do {
                            val event = awaitPointerEvent(PointerEventPass.Initial)
                            val pressed = event.changes.count { it.pressed }
                            if (pressed >= 2) {
                                val zoom = event.calculateZoom()
                                if (zoom != 1f) {
                                    val centroid = event.calculateCentroid(useCurrent = true)
                                    val newScale = (scale * zoom).coerceIn(1f, 8f)
                                    if (!centroid.x.isNaN()) scale = newScale
                                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                                }
                            }
                        } while (event.changes.any { it.pressed })
                    }
                },
        )

        PageTapOverlay(
            viewportSize = viewportSize,
            currentPage = pagerState.currentPage,
            pageCount = pageCount,
            showsHint = !pageTapHintDismissed,
            onAnyZoneTouchDown = onDismissPageTapHint,
            onFirst = { audioVm.let {} ; pagerState.requestScrollToPage(0) },
            onPrev = { pagerState.requestScrollToPage((pagerState.currentPage - 1).coerceAtLeast(0)) },
            onNext = { pagerState.requestScrollToPage((pagerState.currentPage + 1).coerceAtMost(pageCount - 1)) },
            onLast = { pagerState.requestScrollToPage(pageCount - 1) },
        )
    }

    // Auto page-turn (Task 9) is added here as a LaunchedEffect over audioVm.currentCursor.
}
```

> `requestScrollToPage` is the non-suspend pager jump; for animated turns use `rememberCoroutineScope` + `pagerState.animateScrollToPage` (Task 9 adds the scope). Keep this task's tap handlers as immediate jumps; Task 9 upgrades them to animated + adds auto-turn. Drop the stray `audioVm.let {}` — it is a placeholder removed in Task 8 when the overlay lands.

- [ ] **Step 2: Compile-check (will fail until PageTapOverlay exists — that's Task 8)**

This task creates `PagedScore` referencing `PageTapOverlay`, defined in Task 8. Implement Task 8 before compiling. (Sequencing note: Tasks 7 and 8 commit together.)

- [ ] **Step 3: (Deferred commit)** — commit with Task 8.

---

## Task 8: `PageTapOverlay` (4 zones + badge + hint)

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PageTapOverlay.kt`

- [ ] **Step 1: Write the overlay**

`PageTapOverlay.kt` — leading/trailing columns 12% width, split 3:7; press lights all zones; `n / m` badge; first-touch dashed hint:

```kotlin
package com.keynumber.folino.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.FirstPage
import androidx.compose.material.icons.filled.LastPage
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp

@Composable
fun PageTapOverlay(
    viewportSize: IntSize,
    currentPage: Int,
    pageCount: Int,
    showsHint: Boolean,
    onAnyZoneTouchDown: () -> Unit,
    onFirst: () -> Unit,
    onPrev: () -> Unit,
    onNext: () -> Unit,
    onLast: () -> Unit,
) {
    var pressedCount by remember { mutableIntStateOf(0) }
    val highlighted = pressedCount > 0
    val density = LocalDensity.current
    val columnWidth = with(density) { (viewportSize.width * 0.12f).toDp() }

    Box(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxSize()) {
            EdgeColumn(
                width = columnWidth,
                topIcon = Icons.Filled.FirstPage, bottomIcon = Icons.AutoMirrored.Filled.ArrowBack,
                topLabel = "First", bottomLabel = "Prev",
                highlighted = highlighted, showsHint = showsHint,
                onTopTap = onFirst, onBottomTap = onPrev,
                onPressChange = { pressedCount += if (it) 1 else -1; if (it && pressedCount == 1) onAnyZoneTouchDown() },
            )
            Box(Modifier.weight(1f).fillMaxHeight())
            EdgeColumn(
                width = columnWidth,
                topIcon = Icons.Filled.LastPage, bottomIcon = Icons.AutoMirrored.Filled.ArrowForward,
                topLabel = "Last", bottomLabel = "Next",
                highlighted = highlighted, showsHint = showsHint,
                onTopTap = onLast, onBottomTap = onNext,
                onPressChange = { pressedCount += if (it) 1 else -1; if (it && pressedCount == 1) onAnyZoneTouchDown() },
            )
        }
        if (highlighted) {
            Text(
                "${currentPage + 1} / $pageCount",
                color = Color.White,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 24.dp)
                    .background(Color(0x75000000), RoundedCornerShape(50))
                    .padding(horizontal = 14.dp, vertical = 6.dp),
            )
        }
    }
}

@Composable
private fun EdgeColumn(
    width: androidx.compose.ui.unit.Dp,
    topIcon: ImageVector, bottomIcon: ImageVector,
    topLabel: String, bottomLabel: String,
    highlighted: Boolean, showsHint: Boolean,
    onTopTap: () -> Unit, onBottomTap: () -> Unit,
    onPressChange: (Boolean) -> Unit,
) {
    Column(Modifier.width(width).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TapZone(Modifier.weight(0.3f), topIcon, topLabel, highlighted, showsHint, onTopTap, onPressChange)
        TapZone(Modifier.weight(0.7f), bottomIcon, bottomLabel, highlighted, showsHint, onBottomTap, onPressChange)
    }
}

@Composable
private fun TapZone(
    modifier: Modifier,
    icon: ImageVector, label: String,
    highlighted: Boolean, showsHint: Boolean,
    onTap: () -> Unit, onPressChange: (Boolean) -> Unit,
) {
    val shape = RoundedCornerShape(12.dp)
    Box(
        modifier
            .fillMaxWidth()
            .then(if (highlighted) Modifier.background(Color(0x80808080), shape) else Modifier)
            .then(if (showsHint && !highlighted) Modifier.border(1.5.dp, MaterialTheme.colorScheme.primary, shape) else Modifier)
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = {
                        onPressChange(true)
                        tryAwaitRelease()
                        onPressChange(false)
                    },
                    onTap = { onTap() },
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        if (highlighted || showsHint) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(icon, contentDescription = label, tint = if (highlighted) Color.White else MaterialTheme.colorScheme.primary)
                Text(label, color = if (highlighted) Color.White else MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}
```

- [ ] **Step 2: Compile-check the Reader module (Tasks 7 + 8 together)**

```bash
<worktree>/Android/gradlew -p <worktree>/Android :FolinoReaderAndroid:compileDebugKotlin --no-daemon
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit (Tasks 7 + 8)**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PageTapOverlay.kt
git commit -m "feat(reader-android): paged surface + 4-zone tap overlay"
```

---

## Task 9: Auto page-turn on playback cursor

**Files:**
- Modify: `PagedScore.kt`

- [ ] **Step 1: Add cursor → page-index follow + animate tap turns**

In `PagedScore`, add a `rememberCoroutineScope`, switch the tap handlers to `scope.launch { pagerState.animateScrollToPage(target) }`, and add the follow effect. Insert before the final closing brace:

```kotlin
val scope = rememberCoroutineScope()

// Auto page-turn: map the playback cursor's document-Y (mm) to its page band and
// animate to it, unless the user is actively dragging the pager.
LaunchedEffect(scoreHandle, breaksMm) {
    val h = scoreHandle ?: return@LaunchedEffect
    if (breaksMm.size < 2) return@LaunchedEffect
    audioVm.currentCursor.collectLatest { cursor ->
        if (cursor == null) return@collectLatest
        if (pagerState.isScrollInProgress) return@collectLatest // user drag / settling
        val bytes = SheetMusicJNI.nativeCursorFrame(h, ScoreCursorCodec.encode(cursor))
        if (bytes.isEmpty()) return@collectLatest
        val frame = DecodedFrameCodec.decode(bytes)
        val yMm = frame.y.toDouble()
        var target = 0
        for (i in 0 until breaksMm.size - 1) {
            if (yMm >= breaksMm[i] && yMm < breaksMm[i + 1]) { target = i; break }
            if (i == breaksMm.size - 2) target = i // clamp to last
        }
        if (target != pagerState.currentPage) pagerState.animateScrollToPage(target)
    }
}
```

Add imports: `androidx.compose.runtime.rememberCoroutineScope`, `kotlinx.coroutines.flow.collectLatest`, `kotlinx.coroutines.launch`, `io.github.jiyimeta.sheetmusic.SheetMusicJNI`, `io.github.jiyimeta.sheetmusic.audio.serialization.DecodedFrameCodec`, `io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec`. Replace the Task-7 `requestScrollToPage(...)` tap handlers with `scope.launch { pagerState.animateScrollToPage(...) }` and delete the stray `audioVm.let {}`.

- [ ] **Step 2: Compile-check**

```bash
<worktree>/Android/gradlew -p <worktree>/Android :FolinoReaderAndroid:compileDebugKotlin --no-daemon
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt
git commit -m "feat(reader-android): auto page-turn following the playback cursor"
```

---

## Task 10: Wire `PagedScore` into the `PAGE` branch + hint pref

**Files:**
- Modify: `Android/app/.../ui/settings/SettingsPrefs.kt`
- Modify: `Android/FolinoReaderAndroid/.../reader/ReaderScreen.kt`
- Modify: `Android/app/.../MainActivity.kt`

- [ ] **Step 1: Add the hint DataStore key**

In `SettingsPrefs.kt`, add to `SettingsKeys`:

```kotlin
val pageTapHintDismissed = booleanPreferencesKey("reader.pageTapHintDismissed")
```

and to `SettingsPrefs`:

```kotlin
val pageTapHintDismissed: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.pageTapHintDismissed] ?: false }
suspend fun setPageTapHintDismissed() = context.dataStore.edit { it[SettingsKeys.pageTapHintDismissed] = true }
```

- [ ] **Step 2: Route the `PAGE` branch to `PagedScore`**

In `ReaderScreen.kt`, extend the signature and the `when`:

```kotlin
fun ReaderScreen(
    scoreId: String,
    title: String,
    layoutMode: ReaderLayoutMode = ReaderLayoutMode.VERTICAL,
    pageTapHintDismissed: Boolean = false,
    onDismissPageTapHint: () -> Unit = {},
    onBack: () -> Unit,
    readerVm: ReaderViewModel = viewModel(),
    audioVm: ReaderAudioViewModel = viewModel(),
) {
```

```kotlin
is ReaderState.Ready -> when (layoutMode) {
    ReaderLayoutMode.VERTICAL -> ReadyScore(s, scoreHandle, fontProvider, audioVm)
    ReaderLayoutMode.HORIZONTAL -> ReadyScore(s, scoreHandle, fontProvider, audioVm) // separate task
    ReaderLayoutMode.PAGE -> PagedScore(
        state = s,
        scoreHandle = scoreHandle,
        fontProvider = fontProvider,
        audioVm = audioVm,
        readerVm = readerVm,
        pageTapHintDismissed = pageTapHintDismissed,
        onDismissPageTapHint = onDismissPageTapHint,
    )
}
```

- [ ] **Step 3: Thread the hint pref from the app layer**

In `MainActivity.kt`'s reader composable, collect the hint flag and pass both it and the setter (using the existing `rememberCoroutineScope` / add one), alongside the already-wired `layoutMode`:

```kotlin
val layoutPref by prefs.layoutMode.collectAsState(initial = "page")
val hintDismissed by prefs.pageTapHintDismissed.collectAsState(initial = false)
val scope = rememberCoroutineScope()
ReaderScreen(
    scoreId = id,
    title = title,
    layoutMode = ReaderLayoutMode.fromPref(layoutPref),
    pageTapHintDismissed = hintDismissed,
    onDismissPageTapHint = { scope.launch { prefs.setPageTapHintDismissed() } },
    onBack = { nav.popBackStack() },
)
```

Add imports if missing: `androidx.compose.runtime.rememberCoroutineScope`, `kotlinx.coroutines.launch` (already imported in MainActivity).

- [ ] **Step 4: Compile-check the app**

```bash
<worktree>/Android/gradlew -p <worktree>/Android :app:compileDebugKotlin --no-daemon \
  -x generateWireletCodecsMain -x generateWireletObservableViewModelsMain -x generateWireletProvidedInterfacesMain
```

> Exclude the swift-backed wirelet codegen tasks in a fresh worktree (their outputs are copied from the primary checkout); see the wiring-task notes. Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(reader-android): activate page view mode for the PAGE layout pref"
```

---

## Task 11: Device verification (Pixel)

- [ ] **Step 1: Install + launch on a physical Pixel**

```bash
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH \
  <worktree>/Android/gradlew -p <worktree>/Android :app:installDebug --no-daemon
adb shell am start -n com.keynumber.folino/.MainActivity
```

- [ ] **Step 2: Manual checks**

Set Settings → Layout = `page`, open a multi-system score, and verify:
- Swipe left/right turns pages; no neighbouring-system sliver at band edges.
- Each tap zone (first/prev/next/last) works; press lights all zones; `n / m` badge shows; the dashed hint shows once then never again.
- Playback auto-turns to the cursor's page; turning is suppressed while dragging.
- Pinch zoom magnifies within a page and disables swipe; back to unit re-enables swipe.
- Rotate the device: re-paginates without crashing; page index stays in range.
- Settings → Layout = `horizontal` still renders the vertical-scroll fallback.

- [ ] **Step 3: Finish the branch**

Use `superpowers:finishing-a-development-branch` to merge both repos' worktrees to their local `main` (no push unless approved) and tear down the worktrees (`cleanup-worktree.sh` for Folino; `git worktree remove` for ssm).

---

## Self-Review

**Spec coverage:**
- §4.1 shared paginator → Task 1 (+ Task 2 iOS delegation). ✔
- §4.2 `nativePageBreaks` JNI → Task 3. ✔
- §4.3 band-clip render → Task 7. ✔
- §4.4 swipe + 4-zone tap + auto-turn → Tasks 7, 8, 9. ✔
- §4.5 pinch zoom parity → Task 7 (pinch) + Task 9 (swipe lock interplay via `userScrollEnabled = scale == 1f`). ✔
- §5 state (pageBreaks, pager, hint) → Tasks 6, 7, 10. ✔
- §6 cross-repo build/pin → Phase 0, Tasks 4, 5. ✔
- §7 testing → Task 1 tests + Task 11 manual. ✔

**Placeholder scan:** Two intentional, flagged unknowns remain (the real `LayoutDocumentCache` getter name in Task 3 Step 2; the generated JNI binding class in Task 6 Step 2) — both are "verify the existing symbol name" instructions, not invented APIs. The `LayoutSystem.testStub` helper is described with where to source the real initializer. No "TODO/implement later" steps.

**Type consistency:** `breaksMm: DoubleArray` (Kotlin) ↔ `[Double]` mm (Swift) ↔ `PageBreaksWire`/`PageBreaksCodec` big-endian on both sides. `pageBreaks(pageHeightMm)` (VM) ↔ `nativePageBreaks(handle, pageHeightMM)` (JNI). `ScorePaginator.paginate`/`pageBreakOffsets` names consistent across Tasks 1–3 and the iOS delegation. `ReaderLayoutMode.PAGE` branch matches the existing `when` from commit `3bcc8a0`.
