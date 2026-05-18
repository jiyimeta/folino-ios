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
/// 12 % tap zones overlaid on the scroll content; a turn resets
/// `viewportZoom` to 1 and `pendingScroll` to the origin, then changes
/// `pageState.pageIndex` inside `withAnimation` to drive the stack-
/// style slide animation rendered by `PagedZoomedSurface`.
struct PagedScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var pages: [Range<Int>] = []
    /// `pageIndex` lives on an `@Observable` so `withAnimation`
    /// transactions reach the `ScoreScrollHost`-hosted subtree via the
    /// observation system. `UIHostingController` does not forward
    /// animation transactions through `rootView` reassignment — same
    /// hazard documented on `PinchState`.
    @State private var pageState = PageState()
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var contentInsetTop: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    @State private var pinch = PinchState()
    @State private var committedZoom: CGFloat = 1.0

    /// Insets that position the page band inside the full-screen
    /// scroll host: top includes the parent's
    /// `safeAreaPadding(.top, ReaderTopOverlay.height)` so the band
    /// clears the navigation chrome; the other edges are the raw
    /// system insets. Sampled from a sibling reader that ignores the
    /// safe area so the values stay correct even when the scroll host
    /// itself is full-bleed.
    @State private var pageInsets: EdgeInsets = .init()

    private struct PinchSession {
        var baseZoom: CGFloat
    }

    /// Curve applied when mutating `pageState.pageIndex`. Every page in
    /// the rendered window has an `.offset` that depends on `pageIndex`,
    /// so this curve governs every page's slide.
    static let pageTransitionAnimation: Animation = .easeInOut(duration: 0.22)

    /// Horizontal gutter applied to the score content inside the page
    /// band. The layout uses the gutter-deducted width so the score
    /// wraps to its visible width; the page background and tap zones
    /// still span the full band.
    static let horizontalContentPadding: CGFloat = 8

    var body: some View {
        // The outer `GeometryReader` honours both the parent's
        // `safeAreaPadding(.top, ReaderTopOverlay.height)` and the
        // system insets, so `proxy.size` is the visible page band at
        // zoom 1. The scroll host itself is full-bleed (see
        // `scrollContent`), and the hosted surface pads its content
        // by `pageInsets` so it lands inside this same rect — pinch
        // zoom can then expand the page band beyond the safe area
        // toward the screen edges.
        GeometryReader { proxy in
            let viewportWidth = max(proxy.size.width, staffSize * 4)
            let viewportHeight = proxy.size.height
            let viewport = CGSize(width: viewportWidth, height: viewportHeight)
            let contentWidth = max(
                viewportWidth - Self.horizontalContentPadding * 2,
                staffSize * 4,
            )
            scrollContent(viewport: viewport)
                .task(id: TaskKey(
                    score: score, size: staffSize, width: contentWidth,
                    honorLayoutBreaks: honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    pageHeight: viewportHeight,
                )) {
                    await rebuildLayout(
                        width: contentWidth,
                        pageHeight: viewportHeight,
                    )
                }
        }
        .background {
            // Sibling reader extending past the safe area so its
            // `proxy.safeAreaInsets` still reflects the chrome the
            // main GR was inset by. Top includes `ReaderTopOverlay`'s
            // reserve from `ReaderRootScreen.safeAreaPadding(.top, …)`;
            // the other edges are raw system insets.
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: EdgeInsets.self) { proxy in
                    proxy.safeAreaInsets
                } action: { newValue in
                    pageInsets = newValue
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
            centerVertically: false,
            centerHorizontally: false,
            expectedContentSize: {
                // Full-screen content area (= page band + insets) so
                // pinch zoom can stretch the band into the chrome
                // regions. Padding lives inside the hosted surface
                // and scales with zoom (mirrors `VerticalZoomedSurface`).
                CGSize(
                    width: (viewport.width + pageInsets.leading + pageInsets.trailing)
                        * committedZoom,
                    height: (viewport.height + pageInsets.top + pageInsets.bottom)
                        * committedZoom,
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
                pageState: pageState,
                document: document,
                score: score,
                viewport: viewport,
                pageInsets: pageInsets,
                scoreOptions: scoreOptions,
                playbackCursor: playbackCursor,
                lastManualCursor: $lastManualCursor,
                pages: pages,
                onPrevPage: { goToPage(delta: -1) },
                onNextPage: { goToPage(delta: +1) },
                onDoubleTap: { viewModel.toggleZoom(targetIfZoomedOut: 2.0) },
            )
        }
        // Full-bleed so pinch zoom can stretch the page band beyond
        // the safe area into the chrome regions. The hosted surface
        // re-applies `pageInsets` as padding so the band sits inside
        // the safe area at zoom 1.
        .ignoresSafeArea()
        .onChange(of: playbackCursor) { _, newCursor in
            followCursor(newCursor)
        }
    }

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

    private func followCursor(_ cursor: ScoreCursor?) {
        guard let cursor, let doc = document else { return }
        let mi = measureIndex(of: cursor)
        guard let sys = systemIndex(forMeasureIndex: mi, in: doc) else { return }
        guard let target = pages.firstIndex(where: { $0.contains(sys) }) else { return }
        guard target != pageState.pageIndex else { return }
        commitPageTurn(to: target)
    }

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
        let target = pageState.pageIndex + delta
        guard target >= 0, target < pages.count else { return }
        viewModel.resetZoom()
        committedZoom = 1.0
        pinch.magnification = 1.0
        pinch.anchor = .center
        pinch.offsetX = 0
        pinch.offsetY = 0
        commitPageTurn(to: target)
    }

    /// Drive the page turn by mutating `pageIndex` inside `withAnimation`.
    /// `PagedZoomedSurface` keeps the adjacent pages pre-rendered, and
    /// every page's `.offset` is a pure function of its index vs the
    /// current one — so a single `pageIndex` change makes the moving
    /// side interpolate while the static side stays put. No
    /// `slideProgress`, no outgoing tracking, no run-loop hop.
    private func commitPageTurn(to target: Int) {
        withAnimation(Self.pageTransitionAnimation) {
            pageState.pageIndex = target
        }
        pendingScroll = .immediate(.zero)
    }

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
        if pageState.pageIndex >= newPages.count {
            pageState.pageIndex = max(0, newPages.count - 1)
        }
    }

    /// Greedy paginator working in document-Y coordinates. Walks
    /// `systems` in order and closes the current page just before a
    /// system whose bottom edge would extend past
    /// `pageTopDoc + pageHeight`. `pageTopDoc` is `0` for the first
    /// page (so the title frame and any pre-system decorations are
    /// visible) and the previous page's last-system bottom for every
    /// subsequent page (so the gap region above the new page's first
    /// system — which is where rehearsal marks live — renders on the
    /// new page, not the previous one).
    ///
    /// Authored `<LayoutBreak>page` on a system's last measure closes
    /// the page immediately under `.honor` / `.ignoreSystemBreaks`;
    /// `.ignoreAll` lets pages keep packing until vertical overflow.
    static func paginate(
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
                pageTopDoc = systems[index - 1].origin.y
                    + systems[index - 1].size.height
            }
            if policy != .ignoreAll,
               system.measures.last?.pageBreak == true
            {
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

private struct PagedZoomedSurface: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    /// Observed directly so the parent's `withAnimation` on `pageIndex`
    /// reaches this subtree via observation — the `UIHostingController`
    /// boundary swallows animation transactions delivered through
    /// `rootView` reassignment, which would make the turn snap if we
    /// passed `pageIndex` by parameter.
    @Bindable var pageState: PageState
    let document: LayoutDocument?
    let score: Score
    let viewport: CGSize
    let pageInsets: EdgeInsets
    let scoreOptions: ScoreViewOptions
    let playbackCursor: ScoreCursor?
    @Binding var lastManualCursor: ScoreCursor?
    let pages: [Range<Int>]
    let onPrevPage: () -> Void
    let onNextPage: () -> Void
    let onDoubleTap: () -> Void

    var body: some View {
        if let doc = document, !pages.isEmpty {
            let zoom = viewModel.viewportZoom
            let paddedWidth = viewport.width + pageInsets.leading + pageInsets.trailing
            let paddedHeight = viewport.height + pageInsets.top + pageInsets.bottom
            let framedWidth = paddedWidth * zoom
            let framedHeight = paddedHeight * zoom
            let currentIdx = min(max(pageState.pageIndex, 0), pages.count - 1)
            // Keep both neighbors pre-rendered so a page turn never has
            // to spin up a fresh `ScoreView` at tap time — the pages
            // already exist in the tree, only their offsets animate.
            // Pages with `idx < currentIdx` sit at offset `-width`
            // (off-screen leading); pages with `idx >= currentIdx` sit
            // at offset `0`. `zIndex = -Double(idx)` keeps lower indices
            // on top, so the previous page covers the current while
            // sliding in (backward) and the current page covers the
            // next while sliding off (forward).
            let windowIndices: [Int] = [-1, 0, 1].compactMap { delta in
                let idx = currentIdx + delta
                return (0 ..< pages.count).contains(idx) ? idx : nil
            }

            ZStack(alignment: .topLeading) {
                ForEach(windowIndices, id: \.self) { idx in
                    pageContent(forPage: idx, doc: doc)
                        .offset(x: idx >= currentIdx ? 0 : -viewport.width)
                        .zIndex(-Double(idx))
                }
                // Tap zones stay above the pages and do not animate —
                // they are fixed UI affordances, not part of the page
                // band.
                tapOverlay()
            }
            // Clip neighbors to the page band. Without this, the
            // pre-rendered previous page (offset `-viewport.width`)
            // leaks out the leading side whenever the band does not
            // fully cover the host: pinch zoom-out below 100 %, and
            // landscape orientations where `pageInsets.leading` adds
            // a safe-area gap to the left of the band. Clipping the
            // ZStack to its own viewport-sized footprint masks the
            // off-screen page without affecting the slide animation.
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .clipped()
            // Inset the band by `pageInsets` so at zoom 1 it lands
            // inside the safe area + overlay reserve. Padding lives
            // *inside* the scale chain (matches `VerticalZoomedSurface`)
            // so pinch zoom expands the band into the chrome regions
            // proportionally.
            .padding(pageInsets)
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

    private func pageContent(
        forPage idx: Int,
        doc: LayoutDocument,
    ) -> some View {
        let pageRange = pages[idx]
        let lastSystemIndex = pageRange.upperBound - 1
        // Start the clip from the previous page's last-system bottom
        // (or `0` for the first page) so the gap above the current
        // page's first system — where rehearsal marks sit, plus the
        // title frame on page 0 — renders here rather than on the
        // previous page.
        let pageStartY = PagedZoomedSurface.pageStartY(
            forPage: idx, pages: pages, doc: doc,
        )
        let pageEndY: CGFloat = (0 ..< doc.systems.count).contains(lastSystemIndex)
            ? doc.systems[lastSystemIndex].origin.y
            + doc.systems[lastSystemIndex].size.height
            : pageStartY
        let pageHeight = max(0, pageEndY - pageStartY)
        return scoreSurface(
            document: doc,
            pageStartY: pageStartY,
            pageHeight: pageHeight,
        )
        // Inset the score by the shared horizontal gutter so the page
        // background still spans the full band but the music itself
        // sits inboard. The layout uses the same gutter-deducted width,
        // so the score wraps to fit inside.
        .padding(.horizontal, PagedScoreContainer.horizontalContentPadding)
            // White fills the full viewport so any unused space beneath
            // the last system on this page reads as part of the page
            // (just like `SheetMusicUI.PagedScoreView`'s canvas) rather
            // than the host scroll background.
            .frame(width: viewport.width, height: viewport.height, alignment: .top)
            .background(Color.white)
    }

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
        .frame(height: doc.size.height, alignment: .topLeading)
        .offset(y: -pageStartY)
        // `.topLeading` (not `.top`) prevents the default `.center`
        // horizontal alignment from drifting the doc when
        // `doc.size.width` ≠ inner width — which would clip part-
        // labels on the leading edge (e.g. "Lead" → "ead").
        .frame(
            width: viewport.width - PagedScoreContainer.horizontalContentPadding * 2,
            height: pageHeight,
            alignment: .topLeading,
        )
        .clipped()
    }

    private func tapOverlay() -> some View {
        HStack(spacing: 0) {
            PageTapZone(
                width: viewport.width * 0.12,
                height: viewport.height,
                action: onPrevPage,
            )
            Color.clear
                .frame(width: viewport.width * 0.76)
                .allowsHitTesting(false)
            PageTapZone(
                width: viewport.width * 0.12,
                height: viewport.height,
                action: onNextPage,
            )
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }

    private func tapSeekGesture(document: LayoutDocument) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named("scoreSurface"))
            .onEnded { value in
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.setManualCursor(cursor)
                lastManualCursor = cursor
            }
    }

    /// First page renders from doc-Y `0` (so the title frame and any
    /// pre-system decoration are visible); every subsequent page
    /// starts at the previous page's last-system bottom (so the gap
    /// above its own first system — rehearsal marks, etc. — lands on
    /// the right page).
    fileprivate static func pageStartY(
        forPage index: Int,
        pages: [Range<Int>],
        doc: LayoutDocument,
    ) -> CGFloat {
        guard index > 0 else { return 0 }
        let prevLastIndex = pages[index - 1].upperBound - 1
        guard (0 ..< doc.systems.count).contains(prevLastIndex) else { return 0 }
        return doc.systems[prevLastIndex].origin.y
            + doc.systems[prevLastIndex].size.height
    }
}

/// Page-turn tap zone that tints itself with a translucent accent
/// color while the finger is on it, then fires `action` on release
/// inside the zone.
/// `DragGesture(minimumDistance: 0)` drives press tracking via
/// `@GestureState` (auto-resets on lift/cancel) and decides whether
/// the release counts as a tap by checking the final location.
private struct PageTapZone: View {
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    @GestureState private var isPressed = false

    var body: some View {
        Color.accentColor
            .opacity(isPressed ? 0.15 : 0)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in state = true }
                    .onEnded { value in
                        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                        if bounds.contains(value.location) { action() }
                    },
            )
    }
}
