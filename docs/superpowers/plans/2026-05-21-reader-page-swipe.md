# Reader page-mode swipe navigation — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add horizontal swipe page navigation to Reader's page mode, with the adjacent page visually following the finger, gated to zoom ≈ 1.0 with no active pinch.

**Architecture:** Pure decision function `outcome(...)` on `PagedScoreContainer` makes commit/cancel decisions from drag values (fully unit-testable). `PageState` gains `dragTranslationX` and `isDragging`. The neighbor-page offset rule in `PagedZoomedSurface` goes from two-way (`<` vs `>=`) to three-way (`<`, `==`, `>`), and every page's offset becomes `baseline + dragTranslationX`. A `DragGesture(minimumDistance: 8)` on the score surface drives the gesture; on end it dispatches through `outcome(...)` to either `commitPageTurn` (animated `pageIndex` ± 1 inside the existing `pageTransitionAnimation`) or a snap-back animation on `dragTranslationX`.

**Tech Stack:** SwiftUI `DragGesture`, `withAnimation`, existing `@Observable` `PageState`, Swift Testing for the decision function.

---

## Spec reference

Spec: `docs/superpowers/specs/2026-05-21-reader-page-swipe-design.md`. The plan implements every section of that document; in particular sections 3 (drag-following render model), 4 (commit / cancel / rubber-band), and the decision function described in "Commit / cancel decision".

## File map

- **Modify** `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift`
  - Add `PageSwipeOutcome` enum.
  - Add `static func outcome(...)` on `PagedScoreContainer`.
  - Inside `PagedZoomedSurface.body`: change `baseOffset` to three-way and add `+ pageState.dragTranslationX` to the page `.offset`.
  - Inside `scoreSurface(...)`: attach `DragGesture` next to the existing `tapSeekGesture`.
  - Inside `PagedScoreContainer`: add drag handlers (`onSwipeChanged`, `onSwipeEnded`) and a gate predicate.
  - Inside `followCursor`: early-return when `pageState.isDragging`.
- **Modify** `Packages/Features/Reader/Sources/Reader/Screens/PageState.swift`
  - Add `var dragTranslationX: CGFloat = 0`
  - Add `var isDragging = false`
- **Create** `Packages/Features/Reader/Tests/ReaderTests/PageSwipeOutcomeTests.swift`

No other files change. No localized strings, no settings keys, no `xcstrings`, no `project.yml`.

---

## Task 1: Decision function with full TDD

**Files:**
- Create: `Packages/Features/Reader/Tests/ReaderTests/PageSwipeOutcomeTests.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift` (top-level enum + static func on the struct)

- [ ] **Step 1: Write the failing test file**

```swift
import CoreGraphics
@testable import Reader
import Testing

struct PageSwipeOutcomeTests {
    private let viewport: CGFloat = 400

    @Test func `left drag past 30 percent commits next`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -125, predictedEndX: -125,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .commitNext)
    }

    @Test func `right drag past 30 percent commits previous`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: 125, predictedEndX: 125,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .commitPrevious)
    }

    @Test func `under-threshold drag cancels`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -80, predictedEndX: -80,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .cancel)
    }

    @Test func `fling above threshold commits even when translation below`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -40, predictedEndX: -300,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .commitNext)
    }

    @Test func `right fling above threshold from small drag commits previous`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: 40, predictedEndX: 300,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .commitPrevious)
    }

    @Test func `right drag at first page cancels regardless of distance`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: 250, predictedEndX: 400,
            viewportWidth: viewport,
            isAtFirstPage: true, isAtLastPage: false,
        )
        #expect(outcome == .cancel)
    }

    @Test func `left drag at last page cancels regardless of distance`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -250, predictedEndX: -400,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: true,
        )
        #expect(outcome == .cancel)
    }

    @Test func `at first page, left commit still works`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -125, predictedEndX: -125,
            viewportWidth: viewport,
            isAtFirstPage: true, isAtLastPage: false,
        )
        #expect(outcome == .commitNext)
    }

    @Test func `at last page, right commit still works`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: 125, predictedEndX: 125,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: true,
        )
        #expect(outcome == .commitPrevious)
    }

    @Test func `zero viewport width defensively cancels`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -200, predictedEndX: -400,
            viewportWidth: 0,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .cancel)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `cd Packages/Features/Reader && swift test --filter PageSwipeOutcomeTests`
Expected: build failure — `PagedScoreContainer.outcome` does not exist, `PageSwipeOutcome` cases unresolved.

- [ ] **Step 3: Add `PageSwipeOutcome` enum and `outcome` function**

In `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift`, add this enum at file scope just above the `PagedScoreContainer` struct declaration (after the `// swiftlint:disable file_length` line and imports):

```swift
/// Result of evaluating a page-swipe gesture release. `commit*` cases advance / retreat by one page; `cancel`
/// snaps `dragTranslationX` back to 0 without changing `pageIndex`.
enum PageSwipeOutcome: Equatable {
    case commitPrevious
    case commitNext
    case cancel
}
```

Inside `PagedScoreContainer` (anywhere alongside the other `static` helpers, e.g. immediately above `static func paginate`), add:

```swift
/// Pure decision: given a drag's final translation, its `DragGesture.Value.predictedEndTranslation.width` (i.e.
/// the fling-projection), the page-band viewport width, and whether the current page is at either extreme, decide
/// whether the drag should commit a page turn or snap back.
///
/// Rules:
/// - At first / last page, drags that would commit "off the edge" cancel regardless of distance (the rubber-band
///   damping in the view never lets the visual travel cross the commit threshold, but this is the source of truth).
/// - Otherwise commit when either the static progress or the predicted-end progress exceeds 30 % of viewport
///   width in the same direction. The 30 % threshold matches Apple's "page" feel; the predicted-end branch is the
///   fling path that lets a fast, short drag still flip the page.
static func outcome(
    translationX: CGFloat,
    predictedEndX: CGFloat,
    viewportWidth: CGFloat,
    isAtFirstPage: Bool,
    isAtLastPage: Bool,
) -> PageSwipeOutcome {
    guard viewportWidth > 0 else { return .cancel }
    if translationX > 0, isAtFirstPage { return .cancel }
    if translationX < 0, isAtLastPage { return .cancel }

    let threshold: CGFloat = 0.3
    let progress = translationX / viewportWidth
    let predictedProgress = predictedEndX / viewportWidth

    if progress > threshold || predictedProgress > threshold {
        return .commitPrevious
    }
    if progress < -threshold || predictedProgress < -threshold {
        return .commitNext
    }
    return .cancel
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Packages/Features/Reader && swift test --filter PageSwipeOutcomeTests`
Expected: 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift Packages/Features/Reader/Tests/ReaderTests/PageSwipeOutcomeTests.swift
git commit -m "Add PageSwipeOutcome decision function for Reader page-mode swipe"
```

---

## Task 2: Add drag state to PageState

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/PageState.swift`

- [ ] **Step 1: Add the two stored properties**

Edit `PageState.swift`. After the existing `var freezeFirstPageOffset = false` line, add:

```swift
/// Live drag translation while a page-swipe drag is tracking; `0` at rest. Every page's `.offset` in
/// `PagedZoomedSurface` adds this on top of its `pageIndex`-derived baseline, so the entire band slides with
/// the finger. On commit, mutating this back to `0` together with `pageIndex` inside one `withAnimation`
/// transaction makes the existing `pageTransitionAnimation` interpolate the residual slide; on cancel, animate
/// this alone back to `0`.
var dragTranslationX: CGFloat = 0

/// `true` while a page-swipe `DragGesture` is in progress (between first `onChanged` past the activation gate
/// and `onEnded`). While `true`, `PagedScoreContainer.followCursor` no-ops so a playback-driven `commitPageTurn`
/// does not yank the band out from under the finger. The drag-end handler reruns `followCursor` once.
var isDragging = false
```

- [ ] **Step 2: Build the package to verify the file still compiles**

Run: `cd Packages/Features/Reader && swift build`
Expected: build succeeds (PageState is the only file changed; nothing references the new properties yet).

- [ ] **Step 3: Run the existing test suite for the package as smoke**

Run: `cd Packages/Features/Reader && swift test`
Expected: all tests pass (the new properties default to 0 / false; no behavioural change).

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PageState.swift
git commit -m "Add drag state to Reader PageState for page-mode swipe"
```

---

## Task 3: Three-way offset baseline + drag translation in PagedZoomedSurface

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift` (inside `PagedZoomedSurface.body`)

This task introduces the rendering change with `dragTranslationX = 0` everywhere, so at rest the visible behaviour is invariant. The only at-rest difference is that the next page (idx > currentIdx) sits at `+viewport.width` instead of `0` underneath — invisible because the page band's `.clipped()` rejects everything outside the viewport rectangle. The tap-based forward page turn animation now also has the next page slide in from the right (rather than the current page sliding off a static next page); this is the design's accepted cosmetic change, in exchange for a single coherent carousel model that drag-following can hook into directly.

- [ ] **Step 1: Locate the existing baseline expression**

In `PagedZoomedSurface.body`, find this block (currently inside the inner `ZStack(alignment: .topLeading)` that draws pages):

```swift
ForEach(windowIndices, id: \.self) { idx in
    let inSlideWindow = slideSet.contains(idx)
    let baseOffset: CGFloat = idx >= currentIdx
        ? 0 : -viewport.width
    let frozenFirstPage = idx == 0
        && pageState.freezeFirstPageOffset
    pageContent(forPage: idx, doc: doc)
        // ... existing comment block ...
            .offset(x: frozenFirstPage ? 0 : baseOffset)
```

- [ ] **Step 2: Replace `baseOffset` with the three-way rule and add `dragTranslationX` to the offset**

Change the `let baseOffset` line and the `.offset(x:)` line to:

```swift
ForEach(windowIndices, id: \.self) { idx in
    let inSlideWindow = slideSet.contains(idx)
    // Three-way baseline (was two-way `< current` / `>= current`). Now the page after current sits off-screen
    // *trailing* at `+viewport.width` so a leftward drag can reveal it; previous still sits off-screen leading at
    // `-viewport.width`. `freezeFirstPageOffset` overrides idx 0 to hold at `0` during jump-from / jump-to-first
    // transitions, same as before.
    let baseOffset: CGFloat = if idx < currentIdx {
        -viewport.width
    } else if idx == currentIdx {
        0
    } else {
        viewport.width
    }
    let frozenFirstPage = idx == 0
        && pageState.freezeFirstPageOffset
    pageContent(forPage: idx, doc: doc)
        // ... existing comment block ...
            .offset(
                x: (frozenFirstPage ? 0 : baseOffset)
                    + pageState.dragTranslationX,
            )
```

Update the long doc comment immediately above `.offset(x:)` to reflect the three-way rule. Replace its body with:

```swift
                            // Offset is `baseline + dragTranslationX`, where baseline is a pure function of `idx`
                            // vs `currentIdx`: `< current` → `-viewport.width`, `== current` → `0`, `> current` →
                            // `+viewport.width`. Drag-following adds the live finger translation; commit folds
                            // `dragTranslationX` back to `0` inside the same `withAnimation` transaction that
                            // bumps `pageIndex`, so each page interpolates from "old baseline + drag" to
                            // "new baseline + 0" in one motion. Edge pages stay at their baseline so entering /
                            // leaving the window doesn't animate their offset — only opacity crossfades.
                            //
                            // For jumps that involve idx 0 the container raises `freezeFirstPageOffset` so idx 0
                            // holds at `0` for the duration — jump-to-first then fades in at center (like
                            // jump-to-last) instead of sliding rightward from `-viewport.width`.
```

- [ ] **Step 3: Update the comment block above the slide-window construction**

Find this block immediately above the `slideSet` declaration in `PagedZoomedSurface.body`:

```swift
// Keep both neighbors pre-rendered so a page turn never has to spin up a fresh `ScoreView` at tap time —
// the pages already exist in the tree, only their offsets animate. Pages with `idx < currentIdx` sit at
// offset `-width` (off-screen leading); pages with `idx >= currentIdx` sit at offset `0`. `zIndex =
// -Double(idx)` keeps lower indices on top, so the previous page covers the current while sliding in
// (backward) and the current page covers the next while sliding off (forward).
```

Replace with:

```swift
// Keep both neighbors pre-rendered so a page turn never has to spin up a fresh `ScoreView` at tap time —
// the pages already exist in the tree, only their offsets animate. Three-way baseline: `idx < currentIdx`
// sits at `-viewport.width` (off-screen leading), `idx == currentIdx` at `0`, `idx > currentIdx` at
// `+viewport.width` (off-screen trailing). Adding `pageState.dragTranslationX` lets a drag slide every
// page in unison so the neighbor reveals on the side the finger is pulling from. `zIndex = -Double(idx)`
// still keeps lower indices on top — irrelevant during the slide (pages don't overlap) but used when
// drag-following pushes a sub-pixel sliver past zero.
```

- [ ] **Step 4: Build and run existing tests**

Run: `cd Packages/Features/Reader && swift test`
Expected: all tests pass. The change is structural; existing pagination tests are unaffected.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift
git commit -m "Switch Reader page-mode offset to three-way baseline + drag translation"
```

---

## Task 4: Wire the drag gesture into the score surface

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift`

This is the largest task — it wires the live drag, the gate, the rubber band, the commit/cancel dispatch through `outcome(...)`, and the `followCursor` suppression. After it lands the feature is functionally complete.

- [ ] **Step 1: Add drag handlers and the gate predicate to `PagedScoreContainer`**

In `PagedScoreContainer` (the outer struct), add these new private methods alongside the existing `goToPage` / `jumpToPage` / `commitPageTurn`. Place them immediately after `commitPageTurn`:

```swift
/// Page-swipe activation gate. Returns `true` only when the existing page-band state allows a finger-following
/// drag: at unit zoom, with no pinch in flight, and on a multi-page document. The 0.001 epsilon guards against
/// floating-point drift; pinch-snap already lands exactly on `1.0` for the in-tree zoom-out path.
private var pageSwipeEnabled: Bool {
    abs(viewModel.viewportZoom - 1.0) < 0.001
        && pinchSession == nil
        && pages.count > 1
}

/// Rubber-band damping for the edge-overshoot case. Asymptotes at half the viewport width so the drag still
/// reads as "tracking the finger" without ever crossing the commit threshold.
private static func dampedTranslation(
    raw: CGFloat,
    viewportWidth: CGFloat,
) -> CGFloat {
    guard viewportWidth > 0 else { return 0 }
    let magnitude = abs(raw)
    let damped = viewportWidth * (1 - 1 / (1 + magnitude / viewportWidth))
    return raw < 0 ? -damped : damped
}

/// Live drag → `dragTranslationX`. Applies rubber-band damping on the impossible-commit side. Idempotent for
/// gated-off drags (drops the update without touching state).
private func onSwipeChanged(
    translationX: CGFloat,
    viewportWidth: CGFloat,
) {
    guard pageSwipeEnabled else { return }
    pageState.isDragging = true
    let atFirst = pageState.pageIndex == 0
    let atLast = pageState.pageIndex == pages.count - 1
    let needsDamping = (translationX > 0 && atFirst)
        || (translationX < 0 && atLast)
    pageState.dragTranslationX = needsDamping
        ? Self.dampedTranslation(raw: translationX, viewportWidth: viewportWidth)
        : translationX
}

/// Drag release → run through `outcome` and dispatch. Commit folds `dragTranslationX` back into the
/// `commitPageTurn` animation; cancel snaps back with a shorter curve. Either way, `isDragging` clears and
/// `followCursor` re-runs against the current `playbackCursor` so playback-driven advancement that fired
/// during the drag is honoured exactly once at the end.
private func onSwipeEnded(
    translationX: CGFloat,
    predictedEndX: CGFloat,
    viewportWidth: CGFloat,
) {
    guard pageState.isDragging else { return }
    let atFirst = pageState.pageIndex == 0
    let atLast = pageState.pageIndex == pages.count - 1
    let outcome = Self.outcome(
        translationX: translationX,
        predictedEndX: predictedEndX,
        viewportWidth: viewportWidth,
        isAtFirstPage: atFirst,
        isAtLastPage: atLast,
    )

    pageState.isDragging = false

    switch outcome {
    case .commitNext:
        commitDragTurn(to: pageState.pageIndex + 1)
    case .commitPrevious:
        commitDragTurn(to: pageState.pageIndex - 1)
    case .cancel:
        withAnimation(.smooth(duration: 0.18)) {
            pageState.dragTranslationX = 0
        }
    }

    followCursor(playbackCursor)
}

/// Drag-commit variant of `commitPageTurn`. Difference: mutates `pageIndex` and `dragTranslationX` inside the
/// same `withAnimation` block so every page interpolates from "old baseline + drag" to "new baseline + 0" as
/// one motion. No freeze-first-page handling — drag commits are always ±1, never jump-to-edge.
private func commitDragTurn(to target: Int) {
    guard target >= 0, target < pages.count else {
        withAnimation(.smooth(duration: 0.18)) {
            pageState.dragTranslationX = 0
        }
        return
    }
    withAnimation(Self.pageTransitionAnimation) {
        pageState.pageIndex = target
        pageState.dragTranslationX = 0
    }
    pendingScroll = .immediate(.zero)
}
```

- [ ] **Step 2: Add the playback-cursor suppression guard**

Locate the existing `followCursor` method in `PagedScoreContainer`:

```swift
private func followCursor(_ cursor: ScoreCursor?) {
    guard let cursor, let doc = document else { return }
    let mi = measureIndex(of: cursor)
    guard let sys = systemIndex(forMeasureIndex: mi, in: doc) else { return }
    guard let target = pages.firstIndex(where: { $0.contains(sys) }) else { return }
    guard target != pageState.pageIndex else { return }
    commitPageTurn(to: target)
}
```

Change the first guard line to early-return when a swipe drag is in progress:

```swift
private func followCursor(_ cursor: ScoreCursor?) {
    guard !pageState.isDragging else { return }
    guard let cursor, let doc = document else { return }
    let mi = measureIndex(of: cursor)
    guard let sys = systemIndex(forMeasureIndex: mi, in: doc) else { return }
    guard let target = pages.firstIndex(where: { $0.contains(sys) }) else { return }
    guard target != pageState.pageIndex else { return }
    commitPageTurn(to: target)
}
```

- [ ] **Step 3: Attach the drag gesture to the score surface**

Locate the existing `scoreSurface(...)` method in `PagedZoomedSurface`:

```swift
private func scoreSurface(
    document doc: LayoutDocument,
    pageStartY: CGFloat,
    pageHeight: CGFloat,
) -> some View {
    ZStack(alignment: .topLeading) {
        ScoreView(
            document: doc, score: score, options: scoreOptions,
            playbackCursor: playbackCursor, playbackCursorColor: .accentColor,
        )
        .coordinateSpace(name: "scoreSurface")
        .gesture(tapSeekGesture(
            document: doc, pageStartY: pageStartY, pageHeight: pageHeight,
        ))
        .sensoryFeedback(.impact(weight: .medium), trigger: lastManualCursor)
        // ...
```

`scoreSurface` lives inside `PagedZoomedSurface`, but the new drag handlers live on `PagedScoreContainer`. Plumb them as closures the same way `onPrevPage` / `onNextPage` are plumbed. Add four new closure properties on `PagedZoomedSurface` (just under the existing `onDoubleTap`):

```swift
let onSwipeChanged: (CGFloat) -> Void
let onSwipeEnded: (CGFloat, CGFloat) -> Void
```

Then in `PagedScoreContainer.scrollContent(viewport:)`, pass them into the `PagedZoomedSurface(...)` initializer alongside the existing `onDoubleTap` argument:

```swift
PagedZoomedSurface(
    // ... existing arguments ...
    onDoubleTap: { viewModel.toggleZoom(targetIfZoomedOut: 2.0) },
    onSwipeChanged: { translationX in
        onSwipeChanged(translationX: translationX, viewportWidth: viewport.width)
    },
    onSwipeEnded: { translationX, predictedEndX in
        onSwipeEnded(
            translationX: translationX,
            predictedEndX: predictedEndX,
            viewportWidth: viewport.width,
        )
    },
    showsHint: !pageTapHintDismissed,
    onAnyZoneTouchDown: { pageTapHintDismissed = true },
)
```

Now back in `PagedZoomedSurface.scoreSurface`, attach a `DragGesture` next to `tapSeekGesture` using `.simultaneousGesture` so distance disambiguation lets a quick tap still reach tap-seek:

```swift
private func scoreSurface(
    document doc: LayoutDocument,
    pageStartY: CGFloat,
    pageHeight: CGFloat,
) -> some View {
    ZStack(alignment: .topLeading) {
        ScoreView(
            document: doc, score: score, options: scoreOptions,
            playbackCursor: playbackCursor, playbackCursorColor: .accentColor,
        )
        .coordinateSpace(name: "scoreSurface")
        .gesture(tapSeekGesture(
            document: doc, pageStartY: pageStartY, pageHeight: pageHeight,
        ))
        // `minimumDistance: 8` lets a tap (under 8 pt) still reach `tapSeekGesture` via SwiftUI's distance-based
        // disambiguation; crossing 8 pt activates the swipe and cancels tap-seek.
        .simultaneousGesture(pageSwipeGesture())
        .sensoryFeedback(.impact(weight: .medium), trigger: lastManualCursor)
        // ... existing loop overlay block ...
```

Add `pageSwipeGesture()` as a new method on `PagedZoomedSurface`, just below `tapSeekGesture`:

```swift
private func pageSwipeGesture() -> some Gesture {
    DragGesture(minimumDistance: 8, coordinateSpace: .local)
        .onChanged { value in
            // First-sample horizontal-dominance gate: reject vertical-leaning drags so a future vertical-scroll
            // surface (not present today) wouldn't compete with the page swipe. Pure-horizontal drags satisfy
            // `abs(dy) == 0`, well below `abs(dx) / 1.5`.
            guard abs(value.translation.width)
                > abs(value.translation.height) * 1.5
            else { return }
            onSwipeChanged(value.translation.width)
        }
        .onEnded { value in
            onSwipeEnded(value.translation.width, value.predictedEndTranslation.width)
        }
}
```

- [ ] **Step 4: Build the package**

Run: `cd Packages/Features/Reader && swift build`
Expected: build succeeds.

- [ ] **Step 5: Run the package test suite**

Run: `cd Packages/Features/Reader && swift test`
Expected: all tests pass — `PageSwipeOutcomeTests` (10), `PagedScoreContainerPaginateTests` (8), and every other existing suite. The gesture itself is not unit-tested; this run is a smoke check on the changed file.

- [ ] **Step 6: Manual verification in the simulator**

Build the full app and verify the gesture by hand. Page mode is the default Reader display mode (`892e5e6 Default Reader display mode to page`).

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build
xcrun simctl install booted /tmp/Folino-iOS/Build/Products/Debug-iphonesimulator/Folino.app  # adjust DerivedData path as needed
xcrun simctl launch booted com.KeyNumber.Folino
```

(If your DerivedData lives elsewhere, locate the `.app` under `~/Library/Developer/Xcode/DerivedData/Folino-*/Build/Products/Debug-iphonesimulator/Folino.app`.)

Then hand control to the user with this verification checklist — simctl-driven gestures are unreliable for swipe velocity/timing, so the human performs them:

- Open any multi-page score in the Reader at zoom 100 % (page mode is the default).
- Slow drag left past about 30 % of the screen width → next page slides in alongside the finger; on release, page advances and the slide completes smoothly.
- Slow drag left under 30 % → next page peeks; on release, snaps back to current page.
- Fast flick left covering only ~10 % → page advances (fling path).
- Symmetric checks rightward (previous page).
- At first page, drag right → previous side rubber-bands (damps to ~half viewport); on release, snaps back; no commit.
- At last page, drag left → analogous rubber-band.
- Pinch zoom > 1 → drag does not turn pages; existing scroll-host pan takes over.
- Edge tap zones (leading / trailing 12 %) still respond to single taps for jump-to-first / -previous / -next / -last.
- Tap-seek still works inside the central column: a tap with < 8 pt movement moves the playback cursor.
- During playback that crosses a page boundary, a drag held mid-gesture is not yanked; the playback advance lands when the finger lifts.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift
git commit -m "Wire page-swipe DragGesture into Reader page mode"
```

---

## Self-review

Re-checked spec coverage against the four tasks:

- Spec §1 (scope / gating): Task 4 step 1 (`pageSwipeEnabled`).
- Spec §2 (gesture composition): Task 4 step 3 (`DragGesture(minimumDistance: 8)` + horizontal-dominance check).
- Spec §3 (drag-following render model): Task 2 (PageState additions) + Task 3 (three-way baseline + drag translation in offset).
- Spec §4 (rubber band): Task 4 step 1 (`dampedTranslation` and `onSwipeChanged`).
- Spec "Commit / cancel decision" + commit animation continuity: Task 1 (decision function with full test surface) + Task 4 step 1 (`onSwipeEnded` + `commitDragTurn`).
- Spec "Playback-cursor follow conflict": Task 4 step 2 (early-return on `pageState.isDragging`) + Task 4 step 1 (`onSwipeEnded` reruns `followCursor`).
- Spec "Clipping & pinch interaction": already in place — no plan task needed (the existing `.clipped()` survives; the pinch gate is in `pageSwipeEnabled`).
- Spec "Testing": Task 1 covers the decision-function surface listed in the spec. View-level behaviour is manual per Task 4 step 6.

No placeholders. Type / property names are consistent: `PageSwipeOutcome`, `outcome(...)`, `pageSwipeEnabled`, `dampedTranslation(raw:viewportWidth:)`, `onSwipeChanged(translationX:viewportWidth:)`, `onSwipeEnded(translationX:predictedEndX:viewportWidth:)`, `commitDragTurn(to:)`, `dragTranslationX`, `isDragging`. All match across tasks.
