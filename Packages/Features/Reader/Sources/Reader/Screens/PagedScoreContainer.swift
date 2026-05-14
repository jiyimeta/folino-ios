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
    @State private var pageIndex = 0
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
        guard target != pageIndex else { return }
        pageIndex = target
        pendingScroll = .immediate(.zero)
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
