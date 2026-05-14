# Reader page mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `.page` `ReaderLayoutMode` that paginates the score by viewport height, with left/right margin taps for page nav, pinch/pan via `ScoreScrollHost`, and the existing tap-to-seek / playback-cursor / AB-loop affordances.

**Architecture:** New `PagedScoreContainer` modeled on `VerticalScoreContainer`. Same `ScoreScrollHost + PinchState` plumbing; layout is fed `viewport.width` once, the resulting `LayoutDocument.systems` are paginated by height into `[Range<Int>]`, and the hosted `ScoreView` is drawn full-height but `.offset(y:).clipped()` to expose only the current page's band. Tap zones live inside the scroll content (12 % each side, full height); page change resets `viewportZoom` to 1. Playback follow auto-advances the page index.

**Tech Stack:** Swift 6.3, SwiftUI, SPM-only feature module. `swift-sheet-music` (`SheetMusicUI`, `SheetMusicLayout`). Swift Testing for unit tests.

---

## File Structure

**New files:**
- `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift` — top-level container + hosted surface + page-flip overlay + `paginate(systems:pageHeight:policy:)` helper (kept private-but-`internal` for testing).
- `Packages/Features/Reader/Tests/ReaderTests/PagedScoreContainerPaginateTests.swift` — pagination logic unit tests.
- `Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift` — rawValue round-trip + identity tests.

**Modified files:**
- `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift` — add `.page` case.
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` — add `.page` switch arm.
- `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift` — add third Picker segment, widen frame.
- `Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift` — add third Picker segment, widen frame.

---

## Task 1: Add `.page` case to `ReaderLayoutMode` (Domain, TDD)

**Files:**
- Test: `Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift` (new)
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`

Goal: lock in the `"page"` rawValue so a future rename can't silently break the `@AppStorage("readerLayoutMode")` contract.

- [ ] **Step 1: Confirm test target shape**

Run: `ls Packages/Domain/Tests/DomainTests/Models 2>/dev/null`. The `Models` directory may not exist yet — create it:

```bash
mkdir -p Packages/Domain/Tests/DomainTests/Models
```

- [ ] **Step 2: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift`:

```swift
@testable import Domain
import Testing

struct ReaderLayoutModeTests {
    @Test func `page case exists with stable rawValue`() {
        // @AppStorage("readerLayoutMode") persists the rawValue; a
        // rename would silently drop user state on the next launch.
        #expect(ReaderLayoutMode.page.rawValue == "page")
    }

    @Test func `all cases survive rawValue round-trip`() {
        for mode in ReaderLayoutMode.allCases {
            #expect(ReaderLayoutMode(rawValue: mode.rawValue) == mode)
        }
    }

    @Test func `allCases contains vertical horizontal page`() {
        #expect(ReaderLayoutMode.allCases == [.vertical, .horizontal, .page])
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd Packages/Domain && swift test --filter ReaderLayoutModeTests
```

Expected: build failure or test failure with `ReaderLayoutMode.page` undefined.

- [ ] **Step 4: Add `.page` to the enum**

Edit `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`:

```swift
public enum ReaderLayoutMode: String, CaseIterable, Sendable, Hashable {
    case vertical
    case horizontal
    case page
}
```

Update the file's existing doc comment block (lines 3–7) to mention the new mode:

```swift
/// How the Reader lays out the score in the viewport.
///
/// `.vertical` wraps systems to fit the view width and scrolls vertically;
/// `.horizontal` lays the score out at its natural width as one long row
/// that scrolls horizontally; `.page` paginates wrapped systems by
/// viewport height and shows one page at a time.
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd Packages/Domain && swift test --filter ReaderLayoutModeTests
```

Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift \
        Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift
git commit -m "Add .page case to ReaderLayoutMode"
```

---

## Task 2: Pagination helper + tests (Reader, TDD)

**Files:**
- Test: `Packages/Features/Reader/Tests/ReaderTests/PagedScoreContainerPaginateTests.swift` (new)
- Create: `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift` (new — bare scaffold for now, just the static `paginate` helper)

Goal: get the pagination math under test before any UI plumbing.

- [ ] **Step 1: Write the failing test file**

Create `Packages/Features/Reader/Tests/ReaderTests/PagedScoreContainerPaginateTests.swift`:

```swift
import CoreGraphics
@testable import Reader
import SheetMusicLayout
import Testing

struct PagedScoreContainerPaginateTests {
    /// Builds a `LayoutSystem` with the requested height. Other fields
    /// are stubbed to the minimum init can swallow — pagination math
    /// only inspects `size.height` and `measures.last?.pageBreak`.
    private static func system(
        height: CGFloat,
        endsWithPageBreak: Bool = false,
    ) -> LayoutSystem {
        let measure = LayoutMeasure(
            measureIndex: 0,
            origin: .zero,
            width: 100,
            elements: [],
            pageBreak: endsWithPageBreak,
        )
        return LayoutSystem(
            origin: .zero,
            size: CGSize(width: 100, height: height),
            measures: [measure],
            staffOrigins: [.zero],
            partLabels: [],
            spanners: [],
            sp: 4,
        )
    }

    @Test func `empty systems yields empty pages`() {
        let pages = PagedScoreContainer.paginate(
            systems: [], pageHeight: 800, policy: .honor,
        )
        #expect(pages.isEmpty)
    }

    @Test func `zero page height yields empty pages defensively`() {
        let pages = PagedScoreContainer.paginate(
            systems: [Self.system(height: 100)],
            pageHeight: 0, policy: .honor,
        )
        #expect(pages.isEmpty)
    }

    @Test func `single small system fits one page`() {
        let pages = PagedScoreContainer.paginate(
            systems: [Self.system(height: 100)],
            pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1])
    }

    @Test func `two systems that both fit go on one page`() {
        let systems = [
            Self.system(height: 200),
            Self.system(height: 300),
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 2])
    }

    @Test func `second system overflows and starts a new page`() {
        let systems = [
            Self.system(height: 500),
            Self.system(height: 400),
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1, 1 ..< 2])
    }

    @Test func `authored pageBreak closes the page under honor`() {
        let systems = [
            Self.system(height: 200, endsWithPageBreak: true),
            Self.system(height: 200),
            Self.system(height: 200),
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1, 1 ..< 3])
    }

    @Test func `authored pageBreak is ignored under ignoreAll`() {
        let systems = [
            Self.system(height: 200, endsWithPageBreak: true),
            Self.system(height: 200),
            Self.system(height: 200),
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .ignoreAll,
        )
        // All three fit vertically; without the page-break closing
        // page 1 they share a single page.
        #expect(pages == [0 ..< 3])
    }

    @Test func `system taller than page emits a single-system page`() {
        let pages = PagedScoreContainer.paginate(
            systems: [Self.system(height: 1200)],
            pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail with a build error**

```bash
cd Packages/Features/Reader && swift test --filter PagedScoreContainerPaginateTests
```

Expected: build failure — `PagedScoreContainer` is undefined.

- [ ] **Step 3: Create the scaffold file with just the paginate helper**

Create `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift`:

```swift
import CoreGraphics
import SheetMusicLayout
import SwiftUI

/// Page-by-page Reader mode. Lays the score out at viewport width (same
/// as `VerticalScoreContainer`), paginates the resulting systems by
/// viewport height, and shows one page at a time. The full `ScoreView`
/// is drawn behind a `.clipped()` band so tap-seek / playback cursor /
/// AB-loop overlays continue to operate in full-document coordinates.
struct PagedScoreContainer: View {
    var body: some View {
        // Placeholder body — populated in Task 3.
        Color.clear
    }

    /// Greedy paginator: walks systems in order, packs them onto the
    /// current page until the next one would overflow `pageHeight`,
    /// then starts a new page. Authored `<LayoutBreak>page` markup on
    /// the last measure of a system closes the page immediately under
    /// `.honor` / `.ignoreSystemBreaks`. Under `.ignoreAll` page breaks
    /// are ignored and pages only close on vertical overflow.
    ///
    /// Mirrors `SheetMusicUI.PagedScoreView.paginate` — that helper is
    /// `internal` to `SheetMusicUI` and not reachable from a consumer,
    /// so we re-implement the ~30 lines here instead of widening the
    /// sheet-music API surface.
    static func paginate(
        systems: [LayoutSystem],
        pageHeight: CGFloat,
        policy: LayoutBreakPolicy,
    ) -> [Range<Int>] {
        guard !systems.isEmpty, pageHeight > 0 else { return [] }
        var pages: [Range<Int>] = []
        var pageStart = 0
        var usedHeight: CGFloat = 0

        for (index, system) in systems.enumerated() {
            let h = system.size.height
            if index > pageStart, usedHeight + h > pageHeight {
                pages.append(pageStart ..< index)
                pageStart = index
                usedHeight = 0
            }
            usedHeight += h

            if policy != .ignoreAll,
               system.measures.last?.pageBreak == true
            {
                pages.append(pageStart ..< (index + 1))
                pageStart = index + 1
                usedHeight = 0
            }
        }
        if pageStart < systems.count {
            pages.append(pageStart ..< systems.count)
        }
        return pages
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd Packages/Features/Reader && swift test --filter PagedScoreContainerPaginateTests
```

Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift \
        Packages/Features/Reader/Tests/ReaderTests/PagedScoreContainerPaginateTests.swift
git commit -m "Add PagedScoreContainer scaffold with pagination helper"
```

---

## Task 3: Flesh out `PagedScoreContainer` — layout, paged surface, taps, pinch, follow

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift`

This task replaces the placeholder body and adds the hosted surface in one rewrite. The container is structurally a near-twin of `VerticalScoreContainer` — read that file once before starting so the shared idioms (PinchState, ScoreScrollHost, expectedContentSize, commitPinch) are fresh.

There are no unit tests for the SwiftUI surface itself (the codebase tests view-model logic, not container plumbing). Manual verification lives in Task 6.

- [ ] **Step 1: Re-read `VerticalScoreContainer.swift` for reference**

Open `Packages/Features/Reader/Sources/Reader/Screens/VerticalScoreContainer.swift` and skim:

- The `@State` block (`document`, `liveScrollOffset`, `pinchSession`, `pendingScroll`, `contentInsetTop`, `pinch`, `committedZoom`).
- `scrollContent(viewport:)` — how `ScoreScrollHost` is configured.
- `commitPinch(...)` — the bounce-back / snap-to-unit / real zoom paths.
- `VerticalZoomedSurface` — how `pinch.magnification` and `committedZoom` compose.

The new container reuses every one of these pieces. It does NOT reuse:

- The fit-to-width helper (`effectiveZoom`) — layout already targets `viewport.width`.
- `safeAreaTop` plumbing — page mode draws inside the same `ignoresSafeArea()` envelope but doesn't pad system 0 differently.
- `autoScroll(cursor:viewport:)` — replaced with a page-index follow.

- [ ] **Step 2: Replace the file contents**

Overwrite `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift` with the version below. (Yes, the file just created in Task 2 is rewritten — the paginate helper is kept verbatim; everything around it is new.)

```swift
// swiftlint:disable file_length
import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Page-by-page Reader mode. Lays the score out at viewport width (same
/// as `VerticalScoreContainer`), paginates the resulting systems by
/// viewport height, and shows one page at a time. The full `ScoreView`
/// is drawn behind a `.clipped()` band so tap-seek / playback cursor /
/// AB-loop overlays continue to operate in full-document coordinates.
///
/// Pinch composition matches `VerticalScoreContainer` (see that file
/// for the rationale on `committedZoom`, the two `scaleEffect`s, and
/// the snap-to-unit two-phase commit). Pages turn from left / right
/// 12 % tap zones overlaid on the scroll content; a page turn resets
/// `viewportZoom` to 1 and `pendingScroll` to the origin.
struct PagedScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var pages: [Range<Int>] = []
    @State private var pageIndex: Int = 0
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var contentInsetTop: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    @State private var pinch = PinchState()
    @State private var committedZoom: CGFloat = 1.0

    private struct PinchSession {
        var baseZoom: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            let layoutWidth = max(proxy.size.width, staffSize * 4)
            scrollContent(viewport: proxy.size)
                .task(id: TaskKey(
                    score: score, size: staffSize, width: layoutWidth,
                    honorLayoutBreaks: honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    pageHeight: proxy.size.height,
                )) {
                    await rebuildLayout(
                        width: layoutWidth,
                        pageHeight: proxy.size.height,
                    )
                }
        }
    }

    private func scrollContent(viewport: CGSize) -> some View {
        ScoreScrollHost(
            contentOffset: $liveScrollOffset,
            contentInsetTop: $contentInsetTop,
            pendingScroll: $pendingScroll,
            alwaysBounceVertical: false,
            alwaysBounceHorizontal: false,
            centerVertically: true,
            centerHorizontally: true,
            expectedContentSize: {
                CGSize(
                    width: viewport.width * committedZoom,
                    height: viewport.height * committedZoom,
                )
            },
            onPinchBegan: { anchor, _ in
                pinchSession = PinchSession(baseZoom: viewModel.viewportZoom)
                pinch.anchor = anchor
                pinch.magnification = 1.0
                pinch.offsetX = 0
                pinch.offsetY = 0
            },
            onPinchChanged: { magnification, translation in
                pinch.magnification = magnification
                // Both axes can be panned during pinch: at zoom 1.0 the
                // scroll view has no scrollable extent, so neither
                // `offsetX` nor `offsetY` is absorbed by
                // `currentOffset`. Bias both.
                pinch.offsetX = translation.x
                pinch.offsetY = translation.y
            },
            onPinchEnded: { magnification, startLocation, currentOffset in
                commitPinch(
                    magnification: magnification,
                    startLocation: startLocation,
                    currentOffset: currentOffset,
                    viewport: viewport,
                )
            },
        ) {
            PagedZoomedSurface(
                viewModel: viewModel,
                pinch: pinch,
                document: document,
                score: score,
                viewport: viewport,
                scoreOptions: scoreOptions,
                playbackCursor: playbackCursor,
                lastManualCursor: $lastManualCursor,
                pages: pages,
                pageIndex: pageIndex,
                onPrevPage: { goToPage(delta: -1) },
                onNextPage: { goToPage(delta: +1) },
                onDoubleTap: { viewModel.toggleZoom(targetIfZoomedOut: 2.0) },
            )
        }
        .ignoresSafeArea()
        .onChange(of: playbackCursor) { _, newCursor in
            followCursor(newCursor)
        }
    }

    /// Folds a finished pinch into `viewportZoom` and queues a scroll
    /// so the content under the user's fingers at release lands on the
    /// same screen position post-commit. Pages don't have a natural
    /// "doc width / height" the way Vertical / Horizontal do — the
    /// scroll extent is just `viewport.size * zoom` — so both axes can
    /// be pan-during-pinch and both reset on commit.
    ///
    /// See `VerticalScoreContainer.commitPinch` for the rationale on
    /// `committedZoom` / the snap-to-unit two-phase animation.
    private func commitPinch(
        magnification: CGFloat,
        startLocation: CGPoint,
        currentOffset: CGPoint,
        viewport: CGSize,
    ) {
        let session = pinchSession ?? PinchSession(baseZoom: viewModel.viewportZoom)
        pinchSession = nil

        let combined = session.baseZoom * magnification
        let targetZoom: CGFloat = combined < 1.05 ? 1.0 : combined
        let ratio = targetZoom / session.baseZoom

        let scrollToTarget = CGPoint(
            x: max(0, currentOffset.x + startLocation.x * (ratio - 1) - pinch.offsetX),
            y: max(0, currentOffset.y + startLocation.y * (ratio - 1) - pinch.offsetY),
        )

        let isBounceBack = targetZoom <= 1.0 && session.baseZoom <= 1.0
        if isBounceBack {
            withAnimation(.smooth(duration: 0.18)) {
                pinch.magnification = 1.0
                pinch.offsetX = 0
                pinch.offsetY = 0
            }
        } else {
            committedZoom = targetZoom
            pendingScroll = .immediate(scrollToTarget)
            let snapToUnit = targetZoom <= 1.0
            if snapToUnit {
                let compensatedMag = combined / targetZoom
                viewModel.resetZoom()
                pinch.magnification = compensatedMag
                DispatchQueue.main.async {
                    withAnimation(.smooth(duration: 0.18)) {
                        pinch.magnification = 1.0
                        pinch.offsetX = 0
                        pinch.offsetY = 0
                    }
                }
            } else {
                viewModel.viewportZoom = targetZoom
                viewModel.captureCurrentZoomAsLast()
                pinch.magnification = 1.0
                pinch.anchor = .center
                pinch.offsetX = 0
                pinch.offsetY = 0
            }
        }
    }

    /// Walks `pages` to find the page containing the cursor's
    /// measure index, then advances or rewinds `pageIndex` to land
    /// on it. Auto-advance keeps the current `viewportZoom` —
    /// only user-driven page taps reset zoom.
    private func followCursor(_ cursor: ScoreCursor?) {
        guard let cursor, let doc = document else { return }
        let mi = measureIndex(of: cursor)
        guard let sys = systemIndex(forMeasureIndex: mi, in: doc) else { return }
        guard let target = pages.firstIndex(where: { $0.contains(sys) }) else { return }
        guard target != pageIndex else { return }
        pageIndex = target
        pendingScroll = .immediate(.zero)
    }

    /// Index of the `LayoutDocument.systems` element containing the
    /// requested measure. `LayoutDocument` doesn't expose this lookup
    /// on its public surface, but every measure-display surface in
    /// the codebase needs the same walk — kept private here rather
    /// than spreading copies; if a third caller appears in Reader,
    /// hoist to a `LayoutDocument` extension in the same file as
    /// `NearestCursor.swift`.
    private func systemIndex(
        forMeasureIndex mi: Int,
        in doc: LayoutDocument,
    ) -> Int? {
        for (i, sys) in doc.systems.enumerated()
            where sys.measures.contains(where: { $0.measureIndex == mi })
        {
            return i
        }
        return nil
    }

    private func goToPage(delta: Int) {
        let target = pageIndex + delta
        guard target >= 0, target < pages.count else { return }
        viewModel.resetZoom()
        committedZoom = 1.0
        pinch.magnification = 1.0
        pinch.anchor = .center
        pinch.offsetX = 0
        pinch.offsetY = 0
        pageIndex = target
        pendingScroll = .immediate(.zero)
    }

    /// Page mode reuses the vertical-mode layout options (wrap to width,
    /// include title frame). The title frame lives on the first system,
    /// which falls on page 0 — no special handling needed.
    private var scoreOptions: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: true, includeTitleFrame: true,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            breakIndicatorVisibility: .none,
            multiMeasureRest: collapseMultiMeasureRests
                ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
                : .disabled,
        )
    }

    private func rebuildLayout(width: CGFloat, pageHeight: CGFloat) async {
        let score = score
        let options = scoreOptions
        let policy: LayoutBreakPolicy = honorLayoutBreaks ? .honor : .ignoreAll
        let newDoc = await Task.detached(priority: .userInitiated) {
            LayoutEngine.layout(
                score: score, options: options, availableWidth: width,
            )
        }.value
        guard !Task.isCancelled else { return }
        let newPages = Self.paginate(
            systems: newDoc.systems,
            pageHeight: pageHeight,
            policy: policy,
        )
        document = newDoc
        pages = newPages
        if pageIndex >= newPages.count {
            pageIndex = max(0, newPages.count - 1)
        }
    }

    /// Greedy paginator: walks systems in order, packs them onto the
    /// current page until the next one would overflow `pageHeight`,
    /// then starts a new page. Authored `<LayoutBreak>page` on the
    /// last measure of a system closes the page immediately under
    /// `.honor` / `.ignoreSystemBreaks`; `.ignoreAll` lets pagination
    /// run purely on vertical fit.
    static func paginate(
        systems: [LayoutSystem],
        pageHeight: CGFloat,
        policy: LayoutBreakPolicy,
    ) -> [Range<Int>] {
        guard !systems.isEmpty, pageHeight > 0 else { return [] }
        var pages: [Range<Int>] = []
        var pageStart = 0
        var usedHeight: CGFloat = 0

        for (index, system) in systems.enumerated() {
            let h = system.size.height
            if index > pageStart, usedHeight + h > pageHeight {
                pages.append(pageStart ..< index)
                pageStart = index
                usedHeight = 0
            }
            usedHeight += h

            if policy != .ignoreAll,
               system.measures.last?.pageBreak == true
            {
                pages.append(pageStart ..< (index + 1))
                pageStart = index + 1
                usedHeight = 0
            }
        }
        if pageStart < systems.count {
            pages.append(pageStart ..< systems.count)
        }
        return pages
    }

    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let width: CGFloat
        let honorLayoutBreaks: Bool
        let collapseMultiMeasureRests: Bool
        let pageHeight: CGFloat

        init(
            score: Score,
            size: CGFloat,
            width: CGFloat,
            honorLayoutBreaks: Bool,
            collapseMultiMeasureRests: Bool,
            pageHeight: CGFloat,
        ) {
            // Same identity proxy as VerticalScoreContainer.TaskKey:
            // structural shape + opening clefs.
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
                ^ score.openingClefSignature
            self.size = size
            self.width = width
            self.honorLayoutBreaks = honorLayoutBreaks
            self.collapseMultiMeasureRests = collapseMultiMeasureRests
            self.pageHeight = pageHeight
        }
    }
}

/// Hosted score subtree. Lives inside `ScoreScrollHost`'s
/// `UIHostingController`. Reads `pinch.*` and `viewModel.viewportZoom`
/// directly so the SwiftUI observation system delivers animated
/// updates inside the host. The container body itself never reads
/// `pinch.*`, mirroring the pattern in `VerticalZoomedSurface`.
private struct PagedZoomedSurface: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    let document: LayoutDocument?
    let score: Score
    let viewport: CGSize
    let scoreOptions: ScoreViewOptions
    let playbackCursor: ScoreCursor?
    @Binding var lastManualCursor: ScoreCursor?
    let pages: [Range<Int>]
    let pageIndex: Int
    let onPrevPage: () -> Void
    let onNextPage: () -> Void
    let onDoubleTap: () -> Void

    var body: some View {
        if let doc = document, !pages.isEmpty {
            let zoom = viewModel.viewportZoom
            let framedWidth = viewport.width * zoom
            let framedHeight = viewport.height * zoom
            let safePageIndex = min(max(pageIndex, 0), pages.count - 1)
            let pageRange = pages[safePageIndex]
            let pageStartY: CGFloat = pageRange.lowerBound < doc.systems.count
                ? doc.systems[pageRange.lowerBound].origin.y
                : 0

            ZStack {
                scoreSurface(document: doc, pageStartY: pageStartY)
                tapOverlay()
            }
            .scaleEffect(pinch.magnification, anchor: pinch.anchor)
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: pinch.offsetX, y: pinch.offsetY)
            .frame(
                width: framedWidth,
                height: framedHeight,
                alignment: .topLeading,
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { _ in onDoubleTap() },
            )
        } else {
            Color.clear
        }
    }

    private func scoreSurface(document doc: LayoutDocument, pageStartY: CGFloat) -> some View {
        // Full `ScoreView` rendered in document coords; `.offset` slides
        // the page-of-interest into the viewport-shaped clipping frame.
        // tap-seek + playback cursor + AB-loop overlay all keep using
        // document coordinates because nothing under `clipped()` is
        // re-anchored.
        ZStack(alignment: .topLeading) {
            ScoreView(
                document: doc, score: score, options: scoreOptions,
                playbackCursor: playbackCursor, playbackCursorColor: .accentColor,
            )
            .coordinateSpace(name: "scoreSurface")
            .gesture(tapSeekGesture(document: doc))
            .sensoryFeedback(.impact(weight: .medium), trigger: lastManualCursor)

            if viewModel.repeatModel.mode == .abLoop {
                LoopRegionOverlay(document: doc, range: viewModel.repeatModel.abRange)
                LoopBoundaryMarkers(
                    document: doc,
                    start: viewModel.repeatModel.pendingRepeatA,
                    end: viewModel.repeatModel.pendingRepeatB,
                )
            }
        }
        .frame(height: doc.size.height, alignment: .top)
        .offset(y: -pageStartY)
        .frame(width: viewport.width, height: viewport.height, alignment: .top)
        .clipped()
    }

    /// Left / right tap zones live in scroll-content coords (this view
    /// is inside the scaled / offset hosting view), so zooming in can
    /// scroll them off-screen — by design (the user pans to a region
    /// of interest and pages don't accidentally flip).
    ///
    /// Debug build (`#if DEBUG`) tints them red at 20 % so they're
    /// visible during development. The middle 76 % is hit-test
    /// transparent so taps fall through to the score's tap-to-seek
    /// gesture.
    private func tapOverlay() -> some View {
        HStack(spacing: 0) {
            tapZone(.leading).onTapGesture { onPrevPage() }
            Color.clear
                .frame(width: viewport.width * 0.76)
                .allowsHitTesting(false)
            tapZone(.trailing).onTapGesture { onNextPage() }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }

    private func tapZone(_ edge: HorizontalEdge) -> some View {
        let width = viewport.width * 0.12
        return Color.clear
            .frame(width: width, height: viewport.height)
            .contentShape(Rectangle())
            #if DEBUG
            .overlay(Color.red.opacity(0.2))
            #endif
    }

    private func tapSeekGesture(document: LayoutDocument) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named("scoreSurface"))
            .onEnded { value in
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.setManualCursor(cursor)
                lastManualCursor = cursor
            }
    }
}
```

- [ ] **Step 3: Verify the paginate tests still pass after the rewrite**

```bash
cd Packages/Features/Reader && swift test --filter PagedScoreContainerPaginateTests
```

Expected: all 7 tests still green (the helper body is unchanged).

- [ ] **Step 4: Build the Reader package to catch type errors**

```bash
cd Packages/Features/Reader && swift build
```

Expected: clean build. If `ReaderPreferences.multiMeasureRestThreshold` doesn't resolve, check the `Reader` source for its actual home (likely `PlaybackPreferences+Initial.swift` or a sibling) — VerticalScoreContainer references it identically, so it's already in-module.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift
git commit -m "Implement PagedScoreContainer body, taps, pinch, follow"
```

---

## Task 4: Wire `.page` into `ReaderRootScreen`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:146-165`

- [ ] **Step 1: Add the `.page` arm to the layoutMode switch**

In `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`, find the block (around lines 146-165):

```swift
switch layoutMode {
case .vertical:
    VerticalScoreContainer(...)
case .horizontal:
    HorizontalScoreContainer(...)
}
```

Replace it with:

```swift
switch layoutMode {
case .vertical:
    VerticalScoreContainer(
        score: visible,
        staffSize: viewModel.layoutModel.staffSize,
        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
        collapseMultiMeasureRests: collapseMultiMeasureRests,
        playbackCursor: viewModel.playbackCursor,
        viewModel: viewModel,
    )
case .horizontal:
    HorizontalScoreContainer(
        score: visible,
        staffSize: viewModel.layoutModel.staffSize,
        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
        collapseMultiMeasureRests: collapseMultiMeasureRests,
        playbackCursor: viewModel.playbackCursor,
        viewModel: viewModel,
    )
case .page:
    PagedScoreContainer(
        score: visible,
        staffSize: viewModel.layoutModel.staffSize,
        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
        collapseMultiMeasureRests: collapseMultiMeasureRests,
        playbackCursor: viewModel.playbackCursor,
        viewModel: viewModel,
    )
}
```

- [ ] **Step 2: Build the Reader package**

```bash
cd Packages/Features/Reader && swift build
```

Expected: clean build. The switch is now exhaustive over all three cases.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift
git commit -m "Wire .page arm into ReaderRootScreen"
```

---

## Task 5: Add the third Picker segment in Settings + VisualInspector

**Files:**
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift:127-138`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift:54-66`

Both Pickers today use SF Symbols only (no text labels) at a fixed 92 pt frame. Adding a third segment requires widening the frame and choosing a Page icon.

- [ ] **Step 1: Modify the SettingsSheet picker**

In `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift`, find the picker (lines 127-138):

```swift
Picker(selection: $layoutModeRaw) {
    Image(systemName: "arrow.up.and.down")
        .tag(ReaderLayoutMode.vertical.rawValue)
    Image(systemName: "arrow.left.and.right")
        .tag(ReaderLayoutMode.horizontal.rawValue)
} label: {
    Text("settings.reader.layout.title", bundle: .module)
}
.pickerStyle(.segmented)
.labelsHidden()
.frame(width: 92)
.fixedSize()
```

Replace with:

```swift
Picker(selection: $layoutModeRaw) {
    Image(systemName: "arrow.up.and.down")
        .tag(ReaderLayoutMode.vertical.rawValue)
    Image(systemName: "arrow.left.and.right")
        .tag(ReaderLayoutMode.horizontal.rawValue)
    Image(systemName: "book.pages")
        .tag(ReaderLayoutMode.page.rawValue)
} label: {
    Text("settings.reader.layout.title", bundle: .module)
}
.pickerStyle(.segmented)
.labelsHidden()
.frame(width: 132)
.fixedSize()
```

- [ ] **Step 2: Build Settings to catch any reference issue**

```bash
cd Packages/Features/Settings && swift build
```

Expected: clean build. The `Settings` package depends on `Domain`, which now exposes `.page` — no further wiring needed.

- [ ] **Step 3: Modify the VisualInspectorScreen picker**

In `Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift`, find the picker (lines 54-66):

```swift
Picker(selection: $layoutModeRaw) {
    Image(systemName: "arrow.up.and.down")
        .tag(ReaderLayoutMode.vertical.rawValue)
    Image(systemName: "arrow.left.and.right")
        .tag(ReaderLayoutMode.horizontal.rawValue)
} label: {
    Text("reader.preferences.layoutDirection", bundle: .module)
}
.pickerStyle(.segmented)
.labelsHidden()
.frame(width: 92)
.fixedSize()
```

Replace with:

```swift
Picker(selection: $layoutModeRaw) {
    Image(systemName: "arrow.up.and.down")
        .tag(ReaderLayoutMode.vertical.rawValue)
    Image(systemName: "arrow.left.and.right")
        .tag(ReaderLayoutMode.horizontal.rawValue)
    Image(systemName: "book.pages")
        .tag(ReaderLayoutMode.page.rawValue)
} label: {
    Text("reader.preferences.layoutDirection", bundle: .module)
}
.pickerStyle(.segmented)
.labelsHidden()
.frame(width: 132)
.fixedSize()
```

- [ ] **Step 4: Build Reader**

```bash
cd Packages/Features/Reader && swift build
```

Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift \
        Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift
git commit -m "Add Page segment to Reader layout pickers"
```

---

## Task 6: Manual verification on Simulator

**Files:** none modified.

Per the project CLAUDE.md, UI behavior validation runs on the simulator (preview alone can't drive playback / gestures with realistic timing). Before running, verify Xcode is open with the Folino project (`mcp__xcode__XcodeListWindows`).

- [ ] **Step 1: Regenerate the Xcode project**

```bash
xcodegen generate
```

Expected: `Folino.xcodeproj` updated to pick up the new `PagedScoreContainer.swift` and test file.

- [ ] **Step 2: Build for simulator**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED. Any failure → fix and re-run.

- [ ] **Step 3: Run the app and step through the checklist**

Boot the simulator, install / launch the app, open a multi-page score (any of the larger fixtures works; e.g. one that wraps to ≥ 3 systems on a phone-width viewport).

Verify each of:

- [ ] Open `Settings → Reader → Layout`. The picker has three segments. The third is the `book.pages` icon. Tapping it dismisses Settings without crashing.
- [ ] Returning to Reader, the score is rendered as a single page in the viewport. The two tap zones are visible as translucent red strips along the left and right edges.
- [ ] Tapping the right strip advances to page 2. Tapping the left strip goes back to page 1.
- [ ] Tap on a note in the middle 76 % — the playback cursor jumps there and a haptic fires.
- [ ] Pinch out to zoom in. The page scales around the pinch point. After release, pan works inside the page. The red tap strips scroll out of the viewport when the content is panned away from them.
- [ ] While zoomed > 1, tap inside the page — seek still works. The tap-zone strips don't fire because they're now off-screen (verify the score doesn't accidentally page-flip from a panned tap landing on a strip's old viewport position).
- [ ] Press play. Watch the cursor walk through the page. When it crosses the last system of the page, the page advances and the cursor is visible on the next page. Zoom is preserved across the auto-advance (zoom out before this check if you tested zoom-in above).
- [ ] Open AB-loop, set markers; the loop overlay appears inside the visible page band. Loop boundary markers track measure positions.
- [ ] Open the `VisualInspector` (the visual settings menu on the bottom toolbar). The same three-segment picker is there; switch between vertical / horizontal / page and confirm each renders the score correctly. The `@AppStorage` value persists.
- [ ] Switch to `.horizontal`, then back to `.page`. Confirm the score re-renders without a stuck old layout.
- [ ] Toggle staff hide / show via the inspector; the page count adjusts on rebuild and `pageIndex` clamps to a valid value.

Any failure → diagnose, fix in the relevant task, re-run.

- [ ] **Step 4: Commit any fixes (if needed)**

If you found and patched anything during verification, commit the fix(es) with a focused message. No commit needed if everything was clean.

---

## Self-Review

**Spec coverage:**
- `ReaderLayoutMode.page` addition → Task 1.
- `PagedScoreContainer` with mirrored pinch/pan → Task 3.
- Left/right tap zones tied to scroll content (12 % each) → Task 3 step 2 (`tapOverlay()`).
- Debug red overlay → Task 3 step 2 (`#if DEBUG`).
- Page change resets `viewportZoom` to 1 → Task 3 step 2 (`goToPage`).
- Auto-advance during playback (zoom preserved) → Task 3 step 2 (`followCursor`).
- Tap-seek + AB-loop + playback cursor preserved → Task 3 step 2 (`scoreSurface` keeps full-doc coords).
- `ReaderRootScreen` switch arm → Task 4.
- Settings + VisualInspector Picker segments + frame widen → Task 5.
- Unit tests for pagination + rawValue → Tasks 1, 2.
- Manual smoke checklist → Task 6.

**Open-followup items from spec (intentionally deferred):** final tap-target affordance, page-count chip, `pageIndex` persistence, cursor-anchored repagination on staff-size change. Not in any task.

**Placeholder scan:** No TBD / TODO / "fill in" strings. All code blocks are complete. No "similar to Task N" references — paginate body is duplicated verbatim in Task 2 step 3 and Task 3 step 2 (intentional: an engineer reading Task 3 out of order shouldn't have to find the helper in another task).

**Type consistency:** `paginate(systems:pageHeight:policy:) -> [Range<Int>]` is the same signature in both tasks. `goToPage(delta:)`, `followCursor(_:)`, `commitPinch(magnification:startLocation:currentOffset:viewport:)` are each defined once. `ReaderLayoutMode.page.rawValue == "page"` is asserted in Task 1 and matched in Task 5's `.tag` calls.
