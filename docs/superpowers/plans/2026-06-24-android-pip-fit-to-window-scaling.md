# Android PiP fit-to-window scaling (iOS parity) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the Android PiP score scaled to the current PiP window so the full system height is always visible at both PiP size stages, matching iOS; and share the PiP window-aspect heuristic between platforms.

**Architecture:** Android PiP renders the live Compose `HorizontalScore` at a **window-height-derived density** (fit-to-height) instead of the fixed device density, so the system fills whatever PiP window size the OS hands it. The window-aspect heuristic (staff-count → aspect) is lifted into `Domain` as one pure function that iOS calls directly and Android calls through the existing `FolinoReaderJNI` swift-java bridge.

**Tech Stack:** Swift 6.3 / SwiftPM (Domain, Reader feature), Swift Testing; swift-java (jextract) JNI bridge → `libFolinoReaderJNI.so`; Kotlin / Jetpack Compose (Android Reader), JUnit 4.

## Global Constraints

- **iOS 26+, Swift 6.3.** Domain is **Foundation-only** (no UIKit/SwiftUI in `Domain`).
- **iOS/Android parity:** shared logic lives once (Domain) and both platforms call it — never a divergent Kotlin re-implementation. (See `Packages/Domain/Sources/Domain/ScrollFollow.swift` for the established pattern.)
- **New tests use Swift Testing** (`import Testing`, `@Test`, `#expect`) on the Swift side; Android unit tests use JUnit 4 (`org.junit.Test`, `assertEquals`) as in `ReaderLayoutDensityTest.kt`.
- **Package tests run via xcodebuild on an iOS Simulator** (`swift test` is broken by the SwiftLint plugin): `xcodebuild test -scheme <Scheme> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` run from the package directory.
- **Android Kotlin unit tests** run via `./gradlew :FolinoReaderAndroid:testDebugUnitTest` from the `Android/` directory.
- **jextract maps Swift `Int` ⇄ Kotlin `Long`** and Swift `Double` ⇄ Kotlin `Double` (see the `nativePlaylistNextAction` call: `index.toLong()`, `.toInt()`).
- **Android PiP aspect hard limit:** Android rejects PiP aspect outside ~`[1/2.39, 2.39]`; `PIP_MAX_ASPECT = 2.34` (`PipAspect.kt`) must remain the Android ceiling. iOS uses `6.0`.
- **Full-screen Reader rendering is untouched** — only the PiP path changes.
- **Work in a git worktree** (base = local `main`) per the repo workflow; do not commit feature code to the primary checkout.

---

## File Structure

**Create:**
- `Packages/Domain/Sources/Domain/PiPLayout.swift` — shared `pipWindowAspect` pure function.
- `Packages/Domain/Tests/DomainTests/PiPLayoutTests.swift` — Domain unit tests.
- `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/PiPFitDensityTest.kt` — Android fit-to-height density unit test.

**Modify:**
- `Packages/Features/Reader/Sources/FolinoReaderJNI/JNISymbols.swift` — add `nativePipWindowAspect`.
- `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPFrameRenderer.swift` — call shared `pipWindowAspect`.
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PipAspect.kt` — add `pipFitPxPerMm` + `PIP_VERTICAL_PAD`; remove `pipAspectForSystemHeight`.
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` — fit-to-height density in `HorizontalScore`; aspect publish via JNI.
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPipContent.kt` — pass `pipFit = true`.

**Regenerate (build artifact, not a source edit):**
- `libFolinoReaderJNI.so` + jextract Java bindings via `Scripts/android-build-reader-libs.sh` (Task 6).

---

## Task 1: Domain `pipWindowAspect` (shared heuristic)

**Files:**
- Create: `Packages/Domain/Sources/Domain/PiPLayout.swift`
- Test: `Packages/Domain/Tests/DomainTests/PiPLayoutTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `func pipWindowAspect(staffCount: Int, aspectNumerator: Double, minAspect: Double, maxAspect: Double) -> Double` (public, Foundation-only).

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/PiPLayoutTests.swift`:

```swift
@testable import Domain
import Foundation
import Testing

struct PiPLayoutTests {
    private let numerator = 6.0
    // iOS bounds.
    private let iosMin = 1.0
    private let iosMax = 6.0
    // Android bounds (OS hard limit on PiP aspect).
    private let andMin = 1.0
    private let andMax = 2.34

    @Test func `single staff hits the platform max (iOS wide, Android clamped)`() {
        #expect(pipWindowAspect(staffCount: 1, aspectNumerator: numerator, minAspect: iosMin, maxAspect: iosMax) == 6.0)
        #expect(pipWindowAspect(staffCount: 1, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 2.34)
    }

    @Test func `two staves: iOS 3.0, Android clamped to 2.34`() {
        #expect(pipWindowAspect(staffCount: 2, aspectNumerator: numerator, minAspect: iosMin, maxAspect: iosMax) == 3.0)
        #expect(pipWindowAspect(staffCount: 2, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 2.34)
    }

    @Test func `three staves land at 2.0 on both platforms`() {
        #expect(pipWindowAspect(staffCount: 3, aspectNumerator: numerator, minAspect: iosMin, maxAspect: iosMax) == 2.0)
        #expect(pipWindowAspect(staffCount: 3, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 2.0)
    }

    @Test func `six staves clamp at the shared square floor`() {
        #expect(pipWindowAspect(staffCount: 6, aspectNumerator: numerator, minAspect: iosMin, maxAspect: iosMax) == 1.0)
        #expect(pipWindowAspect(staffCount: 6, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 1.0)
    }

    @Test func `many staves stay clamped at minAspect (never taller than square)`() {
        #expect(pipWindowAspect(staffCount: 12, aspectNumerator: numerator, minAspect: iosMin, maxAspect: iosMax) == 1.0)
    }

    @Test func `zero or negative staff count is treated as one`() {
        #expect(pipWindowAspect(staffCount: 0, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 2.34)
        #expect(pipWindowAspect(staffCount: -3, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 2.34)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `Packages/Domain`:
```
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:DomainTests/PiPLayoutTests
```
Expected: FAIL — `cannot find 'pipWindowAspect' in scope`. (If the scheme name errors, list with `xcodebuild -list` and use `Domain-Package`.)

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/Domain/Sources/Domain/PiPLayout.swift`:

```swift
import Foundation

/// PiP window aspect ratio (width / height) derived from the rendered system's staff count.
///
/// Fewer staves → a flatter (wider) window; more staves → squarer, bottoming out at `minAspect`
/// (where the renderer shrinks the drawn music to fit the window height instead of growing the
/// window taller). Shared by iOS and Android (parity: one implementation; iOS calls this directly,
/// Android via the `FolinoReaderJNI` bridge — no divergent Kotlin port).
///
/// The heuristic is `aspectNumerator / staffCount`, clamped to `[minAspect, maxAspect]`. `maxAspect`
/// differs by platform: AVKit accepts up to `6.0` on iOS, while Android rejects any PiP aspect outside
/// ~`[1/2.39, 2.39]` and so passes a `2.34` ceiling. `minAspect` is `1.0` on both — the PiP window is
/// never taller than square; tall scores are handled by shrinking the music, not by a taller window.
public func pipWindowAspect(
    staffCount: Int,
    aspectNumerator: Double,
    minAspect: Double,
    maxAspect: Double,
) -> Double {
    let staves = Double(max(1, staffCount))
    return max(minAspect, min(maxAspect, aspectNumerator / staves))
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run from `Packages/Domain`:
```
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:DomainTests/PiPLayoutTests
```
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```
git add Packages/Domain/Sources/Domain/PiPLayout.swift Packages/Domain/Tests/DomainTests/PiPLayoutTests.swift
git commit -m "feat(domain): add shared pipWindowAspect heuristic for PiP window shape"
```

---

## Task 2: iOS — route `ScorePiPFrameRenderer` through `pipWindowAspect`

Pure refactor (identical behavior). The existing `ScorePiPFrameRendererTests` are the regression guard.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPFrameRenderer.swift` (the `aspect` computation in `init`, around lines 170–173)
- Test (existing): `Packages/Features/Reader/Tests/ReaderTests/PiP/ScorePiPFrameRendererTests.swift`

**Interfaces:**
- Consumes: `pipWindowAspect(staffCount:aspectNumerator:minAspect:maxAspect:)` from Task 1.
- Produces: no API change.

- [ ] **Step 1: Replace the inline aspect math**

In `ScorePiPFrameRenderer.init`, replace:

```swift
        let aspect = max(
            Self.minAspect,
            min(Self.maxAspect, Self.aspectNumerator / CGFloat(staffCount)),
        )
```

with:

```swift
        let aspect = CGFloat(pipWindowAspect(
            staffCount: staffCount,
            aspectNumerator: Double(Self.aspectNumerator),
            minAspect: Double(Self.minAspect),
            maxAspect: Double(Self.maxAspect),
        ))
```

(`Domain` is already imported in this file; `Self.minAspect = 1.0`, `Self.maxAspect = 6.0`, `Self.aspectNumerator = 6.0` and `staffCount: Int` are unchanged. Leave those constant declarations in place.)

- [ ] **Step 2: Run the existing PiP renderer tests (regression guard)**

Run from `Packages/Features/Reader`:
```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/ScorePiPFrameRendererTests
```
Expected: PASS (unchanged) — behavior is identical, so the suite stays green.

- [ ] **Step 3: Commit**

```
git add Packages/Features/Reader/Sources/Reader/PiP/ScorePiPFrameRenderer.swift
git commit -m "refactor(reader): use shared pipWindowAspect in iOS PiP renderer"
```

---

## Task 3: `FolinoReaderJNI` — bridge `pipWindowAspect` to Android

**Files:**
- Modify: `Packages/Features/Reader/Sources/FolinoReaderJNI/JNISymbols.swift`

**Interfaces:**
- Consumes: `pipWindowAspect(...)` from Task 1.
- Produces: Swift `nativePipWindowAspect(staffCount: Int, aspectNumerator: Double, minAspect: Double, maxAspect: Double) -> Double`, surfaced after jextract regen (Task 6) as Kotlin `com.keynumber.folino.reader.swiftjava.FolinoReaderJNI.nativePipWindowAspect(Long, Double, Double, Double): Double`.

- [ ] **Step 1: Add the delegation symbol**

Append to `Packages/Features/Reader/Sources/FolinoReaderJNI/JNISymbols.swift`:

```swift
/// swift-java (jextract) entry point for the Android Reader's PiP window aspect. Pure delegation to
/// the shared `Domain.pipWindowAspect` so iOS and Android pick the PiP window shape identically from
/// one implementation (parity — no divergent Kotlin port). Android passes its OS-limited `maxAspect`
/// (2.34); iOS calls `Domain.pipWindowAspect` directly with 6.0.
public func nativePipWindowAspect(
    staffCount: Int,
    aspectNumerator: Double,
    minAspect: Double,
    maxAspect: Double,
) -> Double {
    pipWindowAspect(
        staffCount: staffCount,
        aspectNumerator: aspectNumerator,
        minAspect: minAspect,
        maxAspect: maxAspect,
    )
}
```

- [ ] **Step 2: Verify the JNI target still builds (host)**

Run from `Packages/Features/Reader`:
```
xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```
Expected: BUILD SUCCEEDED (compile check only; the Android `.so`/binding regen happens in Task 6).

- [ ] **Step 3: Commit**

```
git add Packages/Features/Reader/Sources/FolinoReaderJNI/JNISymbols.swift
git commit -m "feat(reader): bridge pipWindowAspect to Android via FolinoReaderJNI"
```

---

## Task 4: Android — `pipFitPxPerMm` fit-to-height density (pure fn + test)

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PipAspect.kt`
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/PiPFitDensityTest.kt`

**Interfaces:**
- Consumes: nothing.
- Produces: `fun pipFitPxPerMm(viewportHeightPx: Int, verticalPadPx: Float, systemHeightMM: Double): Float`; `val PIP_VERTICAL_PAD: Dp` (= 16.dp).

- [ ] **Step 1: Write the failing test**

Create `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/PiPFitDensityTest.kt`:

```kotlin
package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PiPFitDensityTest {
    // 600px window − 16px pad each side = 568px usable; 40mm system → 14.2 px/mm.
    @Test fun fitsSystemHeightIntoWindowMinusPadding() {
        assertEquals(14.2, pipFitPxPerMm(600, 16f, 40.0).toDouble(), 0.01)
    }

    @Test fun smallerWindowYieldsSmallerDensity() {
        val large = pipFitPxPerMm(600, 16f, 40.0)
        val small = pipFitPxPerMm(300, 16f, 40.0)
        assertTrue(small < large)
    }

    @Test fun tallerSystemYieldsSmallerDensity() {
        val short = pipFitPxPerMm(600, 16f, 40.0)
        val tall = pipFitPxPerMm(600, 16f, 80.0)
        assertTrue(tall < short)
    }

    @Test fun degenerateInputsReturnZero() {
        assertEquals(0f, pipFitPxPerMm(0, 16f, 40.0))     // no viewport
        assertEquals(0f, pipFitPxPerMm(600, 16f, 0.0))    // no system height
        assertEquals(0f, pipFitPxPerMm(20, 16f, 40.0))    // padding consumes the whole window
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `Android/`:
```
./gradlew :FolinoReaderAndroid:testDebugUnitTest --tests "com.keynumber.folino.reader.PiPFitDensityTest"
```
Expected: FAIL — `unresolved reference: pipFitPxPerMm`.

- [ ] **Step 3: Write the minimal implementation**

In `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PipAspect.kt`, add the imports and append the function. At the top of the file add:

```kotlin
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
```

Then append:

```kotlin
/** Vertical breathing room (each side) left around the system inside the PiP window. Mirrors iOS's
 *  `ScorePiPFrameRenderer.verticalPaddingPt = 16`. Tunable; confirmed by the iOS side-by-side. */
val PIP_VERTICAL_PAD: Dp = 16.dp

/**
 * Render density (pixels per layout-mm) for the PiP score, chosen so the single system's full height
 * fits the current PiP window height with [verticalPadPx] breathing room on each side. Unlike the
 * full-screen Reader (fixed device-independent [fixedPxPerMm]), PiP scales with the window so the
 * whole system stays visible at every PiP size stage — mirroring iOS, where AVKit scales a fixed
 * buffer to the window. Returns 0 for a degenerate viewport / system so callers can no-op.
 */
fun pipFitPxPerMm(
    viewportHeightPx: Int,
    verticalPadPx: Float,
    systemHeightMM: Double,
): Float {
    if (viewportHeightPx <= 0 || systemHeightMM <= 0.0) return 0f
    val usable = viewportHeightPx - 2f * verticalPadPx
    if (usable <= 0f) return 0f
    return (usable / systemHeightMM).toFloat()
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run from `Android/`:
```
./gradlew :FolinoReaderAndroid:testDebugUnitTest --tests "com.keynumber.folino.reader.PiPFitDensityTest"
```
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PipAspect.kt Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/PiPFitDensityTest.kt
git commit -m "feat(reader-android): add pipFitPxPerMm fit-to-height density"
```

---

## Task 5: Android — render the PiP score fit-to-height

Wire `pipFitPxPerMm` into the `HorizontalScore` PiP path. Compose UI; verified by build + manual PiP check (no unit test — the formula is covered by Task 4).

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (`HorizontalScore`, around lines 1272–1296)
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPipContent.kt`

**Interfaces:**
- Consumes: `pipFitPxPerMm`, `PIP_VERTICAL_PAD` (Task 4).
- Produces: `HorizontalScore(..., pipFit: Boolean = false)` — the full-screen caller keeps the default `false`.

- [ ] **Step 1: Add the `pipFit` parameter to `HorizontalScore`**

In `ReaderScreen.kt`, change the `HorizontalScore` signature (currently ends `layoutOptions: LayoutOptions,`):

```kotlin
internal fun HorizontalScore(
    state: ReaderState.Ready,
    scoreHandle: Long?,
    fontProvider: io.github.jiyimeta.sheetmusic.compose.render.FontProvider,
    audioVm: ReaderAudioViewModel,
    layoutOptions: LayoutOptions,
    pipFit: Boolean = false,
) {
```

- [ ] **Step 2: Compute the density fit-to-height when `pipFit` is on**

In `HorizontalScore`, replace:

```kotlin
    val fitPxPerMM = if (viewportSize.width > 0) fixedPxPerMm(density.density) else 0f
```

with:

```kotlin
    val verticalPadPx = with(density) { PIP_VERTICAL_PAD.toPx() }
    val fitPxPerMM = when {
        viewportSize.width <= 0 -> 0f
        pipFit -> pipFitPxPerMm(viewportSize.height, verticalPadPx, page.heightMM)
        else -> fixedPxPerMm(density.density)
    }
```

(`page` is already `state.program.pages.first()` at the top of `HorizontalScore`; `density` is already `LocalDensity.current`. With fit-to-height the system fits the window, so `needsVScroll` becomes false and the existing short-row vertical-centering branch handles layout — no other change needed.)

- [ ] **Step 3: Pass `pipFit = true` from `ReaderPipContent`**

In `ReaderPipContent.kt`, update the `HorizontalScore` call:

```kotlin
            HorizontalScore(
                state = ReaderState.Ready(p),
                scoreHandle = scoreHandle,
                fontProvider = fontProvider,
                audioVm = audioVm,
                layoutOptions = layoutOptions.copy(mode = ReaderLayoutMode.HORIZONTAL),
                pipFit = true,
            )
```

- [ ] **Step 4: Build the Android app**

Run from `Android/`:
```
./gradlew :app:assembleDebug
```
Expected: BUILD SUCCESSFUL. (If JNI `.so`/bindings are missing in a fresh worktree, see Task 6 Step 1 and `reference_android_fresh_worktree_app_build`.)

- [ ] **Step 5: Install, launch, and verify PiP manually**

Run from `Android/` (emulator `emulator-5554` per the Android workflow):
```
./gradlew :app:installDebug
adb -s emulator-5554 shell am start -n com.KeyNumber.Folino/com.keynumber.folino.MainActivity
```
Then hand off to the user to verify in PiP: open a score, start playback, enter PiP, and check —
- **small stage:** the full system height is visible (finer, not clipped);
- **large stage:** the system fits with breathing room;
- **tall multi-staff score:** the full height fits (shrunk);
- **double-tap resize:** the score rescales smoothly to the new size.

- [ ] **Step 6: Commit**

```
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPipContent.kt
git commit -m "feat(reader-android): render PiP score fit-to-window so full height stays visible"
```

---

## Task 6: Android — publish the PiP aspect via the shared heuristic

Regenerate the JNI binding for `nativePipWindowAspect`, then replace the A4-based aspect publish with the staff-count heuristic and delete `pipAspectForSystemHeight`.

**Files:**
- Regenerate: `libFolinoReaderJNI.so` + jextract Java bindings (via `Scripts/android-build-reader-libs.sh`)
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (aspect-publish `LaunchedEffect`, around lines 302–311)
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PipAspect.kt` (remove `pipAspectForSystemHeight`)

**Interfaces:**
- Consumes: Kotlin `FolinoReaderJNI.nativePipWindowAspect(Long, Double, Double, Double): Double` (Task 3, surfaced here); `mixerParts` (`readerVm.parts`, collected at `ReaderScreen.kt:260`); `layoutOptions.hiddenStaves`; `PIP_MAX_ASPECT` (`PipAspect.kt`).
- Produces: aspect publish no longer depends on `readerVm.horizontalProgram()`; `pipAspectForSystemHeight` removed (`pipAspectClamped` / `PIP_MAX_ASPECT` stay — still used by `buildPipParams`).

- [ ] **Step 1: Regenerate the Reader JNI `.so` + bindings**

Run from the repo root:
```
Scripts/android-build-reader-libs.sh
```
Expected: builds `libFolinoReaderJNI.so` (+ `libSwiftJava.so`, runtime) and the generated Java bindings, staged for the Android module. The new `FolinoReaderJNI.nativePipWindowAspect` symbol is now visible to Kotlin. (Native-drift / fresh-worktree pitfalls: see `project_library_android_native_drift` and `reference_android_fresh_worktree_app_build`.)

- [ ] **Step 2: Replace the aspect-publish effect**

In `ReaderScreen.kt`, replace the existing PiP aspect `LaunchedEffect` (the one that calls `pipAspectForSystemHeight`):

```kotlin
    LaunchedEffect(scoreHandle, layoutOptions, pipEnabled) {
        if (!pipEnabled || scoreHandle == null) return@LaunchedEffect
        val page = readerVm.horizontalProgram()?.pages?.firstOrNull() ?: return@LaunchedEffect
        ReaderPipController.setContentAspect(pipAspectForSystemHeight(page.heightMM, A4_WIDTH_MM))
    }
```

with the staff-count heuristic (iOS counts the rendered system's staves = total minus hidden):

```kotlin
    LaunchedEffect(pipEnabled, mixerParts, layoutOptions.hiddenStaves) {
        if (!pipEnabled) return@LaunchedEffect
        val totalStaves = mixerParts.sumOf { it.staves.size }
        val visibleStaves = (totalStaves - layoutOptions.hiddenStaves.size).coerceAtLeast(1)
        ReaderPipController.setContentAspect(
            com.keynumber.folino.reader.swiftjava.FolinoReaderJNI.nativePipWindowAspect(
                visibleStaves.toLong(), 6.0, 1.0, PIP_MAX_ASPECT,
            ),
        )
    }
```

- [ ] **Step 3: Remove the now-unused A4 aspect helper**

In `PipAspect.kt`, delete `pipAspectForSystemHeight(...)` (the whole function and its doc comment). Keep `PIP_MAX_ASPECT` and `pipAspectClamped`. In `ReaderScreen.kt`, delete the now-unused `A4_WIDTH_MM` constant and its comment (verify no other reference first):
```
git grep -n "A4_WIDTH_MM\|pipAspectForSystemHeight" Android/
```
Expected after edits: no matches.

- [ ] **Step 4: Build, install, verify the window shape**

Run from `Android/`:
```
./gradlew :app:installDebug
adb -s emulator-5554 shell am start -n com.KeyNumber.Folino/com.keynumber.folino.MainActivity
```
Hand off to the user: confirm the PiP window shape is sensible across staff counts — a 1–2 staff score gives a wide (flat) window (clamped at 2.34), a ~3-staff score ~2:1, an orchestral score trends square; and the full system height still fits at both size stages (Task 5 behavior unchanged).

- [ ] **Step 5: Commit**

```
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PipAspect.kt
git commit -m "feat(reader-android): publish PiP window aspect from shared staff-count heuristic"
```

(Commit the regenerated `.so` / bindings only if this repo tracks them — check `git status`; they may be gitignored build artifacts staged for the local build.)

---

## Task 7: Cross-platform integration verification

**Files:** none (verification only).

- [ ] **Step 1: Domain + iOS Reader test suites green**

Run from `Packages/Domain`:
```
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:DomainTests/PiPLayoutTests
```
Run from `Packages/Features/Reader`:
```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/ScorePiPFrameRendererTests
```
Expected: both PASS.

- [ ] **Step 2: Android unit tests green**

Run from `Android/`:
```
./gradlew :FolinoReaderAndroid:testDebugUnitTest
```
Expected: PASS (includes `PiPFitDensityTest` and the existing `ReaderLayoutDensityTest`).

- [ ] **Step 3: iOS app build (no regression on the shared Domain change)**

Run from the repo root:
```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Final manual confirmation (user)**

Confirm on the Android emulator (and, if desired, side-by-side with iOS) that PiP now keeps the full system height visible at both size stages and the window shape matches the staff-count heuristic. iOS PiP behavior is unchanged.

---

## Self-Review

**Spec coverage:**
- Fit-to-height core (small-stage + tall-system overflow) → Tasks 4–5. ✓
- Shared window-aspect heuristic in Domain, both platforms call it → Tasks 1 (Domain), 2 (iOS adopts), 3 + 6 (Android via JNI). ✓
- `minAspect = 1.0` shared, `maxAspect` divergence (iOS 6.0 / Android 2.34) → encoded in Task 1 tests + Task 2/6 call args. ✓
- Breathing room (iOS `verticalPaddingPt = 16`) → `PIP_VERTICAL_PAD = 16.dp` (Task 4), tuned manually (Task 5 Step 5). ✓
- Staff-count sourcing (iOS `staffOrigins.count` → Android total − hidden) → Task 6 Step 2. ✓
- Full-screen Reader untouched → `pipFit` defaults `false`; full-screen caller unchanged (Task 5). ✓
- Tests: Domain (Task 1), iOS regression (Task 2), Android density (Task 4), integration (Task 7). ✓
- `.so` rebuild risk → Task 6 Step 1 with memory cross-refs. ✓

**Type consistency:** `pipWindowAspect(staffCount: Int, aspectNumerator: Double, minAspect: Double, maxAspect: Double) -> Double` is identical across Domain (Task 1), the iOS call (Task 2, wrapped in `CGFloat(...)`), and the JNI wrapper (Task 3). Kotlin call passes `visibleStaves.toLong()` + three `Double`s and receives `Double` (jextract Int⇄Long, Double⇄Double — Global Constraints). `pipFitPxPerMm(Int, Float, Double): Float` matches between Task 4 (def) and Task 5 (call). `pipFit: Boolean = false` matches between Task 5 Step 1 (def) and Step 3 (call).

**Placeholder scan:** none — every code step shows complete code; every run step shows the command and expected result.
