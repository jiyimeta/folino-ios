// swiftlint:disable file_length
import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Result of evaluating a page-swipe gesture release. `commit*` cases advance / retreat by one page; `cancel`
/// snaps `dragTranslationX` back to 0 without changing `pageIndex`.
enum PageSwipeOutcome: Equatable {
    case commitPrevious
    case commitNext
    case cancel
}

/// Page-by-page Reader mode. Lays the score out at viewport width (same as `VerticalScoreContainer`), paginates the
/// resulting systems by viewport height, and shows one page at a time. The full `ScoreView` is drawn behind a
/// `.clipped()` band so tap-seek / playback cursor / AB-loop overlays continue to operate in full-document coordinates.
///
/// Pinch composition matches `VerticalScoreContainer` (see that file for the rationale on `committedZoom`, the two
/// `scaleEffect`s, and the snap-to-unit two-phase commit).
///
/// Navigation lives in `TapOverlay`: a leading / trailing column each `12 %` of the viewport, split `3 : 7` vertically
/// — the top slice jumps to the first / last page, the bottom slice turns one page in the same direction. A capsule
/// page-position badge fades in along with the zones. A page turn resets `viewportZoom` to `1` and `pendingScroll` to
/// the origin, then mutates `pageState.pageIndex` inside `withAnimation` so `PagedZoomedSurface` interpolates the
/// neighbor / edge `.offset`s into the slide / fade transition.
struct PagedScoreContainer: View {
    // swiftlint:disable:previous type_body_length
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var pages: [Range<Int>] = []
    /// `pageIndex` lives on an `@Observable` so `withAnimation` transactions reach the `ScoreScrollHost`-hosted subtree
    /// via the observation system. `UIHostingController` does not forward animation transactions through `rootView`
    /// reassignment — same hazard documented on `PinchState`.
    @State private var pageState = PageState()
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var contentInsetTop: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    @State private var pinch = PinchState()
    @State private var committedZoom: CGFloat = 1.0
    /// `playbackCursor` value captured the moment a page-swipe `DragGesture` starts (the `isDragging` false→true
    /// transition). Compared against the cursor at gesture end to decide whether playback actually advanced through
    /// pages during the swipe — only then should `followCursor` re-run. Without this, a paused-but-still-visible
    /// cursor on a different page yanks the user back to the cursor's page on every swipe end.
    @State private var swipeStartCursor: ScoreCursor?

    /// First-tap onboarding hint state. `false` until the user touches any page-nav zone for the first time, then
    /// permanently `true`. See `ReaderGlobalSettingsKey.pageTapHintDismissed`.
    @AppStorage(ReaderGlobalSettingsKey.pageTapHintDismissed)
    private var pageTapHintDismissed = false

    /// Insets that position the page band inside the full-screen scroll host: top includes the parent's
    /// `safeAreaPadding(.top, ReaderTopOverlay.height)` so the band clears the navigation chrome; the other edges are
    /// the raw system insets. Sampled from a sibling reader that ignores the safe area so the values stay correct even
    /// when the scroll host itself is full-bleed.
    @State private var pageInsets: EdgeInsets = .init()

    private struct PinchSession {
        var baseZoom: CGFloat
    }

    /// Curve applied when mutating `pageState.pageIndex`. Every page in the rendered window has an `.offset` that
    /// depends on `pageIndex`, so this curve governs every page's slide.
    static let pageTransitionAnimation: Animation = .easeOut(duration: 0.18)

    /// Horizontal gutter applied to the score content inside the page band. The layout uses the gutter-deducted width
    /// so the score wraps to its visible width; the page background and tap zones still span the full band.
    static let horizontalContentPadding: CGFloat = 12

    var body: some View {
        // The outer `GeometryReader` honours both the parent's `safeAreaPadding(.top, ReaderTopOverlay.height)` and the
        // system insets, so `proxy.size` is the visible page band at zoom 1. The scroll host itself is full-bleed (see
        // `scrollContent`), and the hosted surface pads its content by `pageInsets` so it lands inside this same rect —
        // pinch zoom can then expand the page band beyond the safe area toward the screen edges.
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
            // Sibling reader extending past the safe area so its `proxy.safeAreaInsets` still reflects the chrome the
            // main GR was inset by. Top includes `ReaderTopOverlay`'s reserve from
            // `ReaderRootScreen.safeAreaPadding(.top, …)`; the other edges are raw system insets.
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: EdgeInsets.self) { proxy in
                    proxy.safeAreaInsets
                } action: { newValue in
                    pageInsets = newValue
                }
        }
    }

    // swiftlint:disable:next function_body_length
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
                // Full-screen content area (= page band + insets) so pinch zoom can stretch the band into the chrome
                // regions. Padding lives inside the hosted surface and scales with zoom (mirrors
                // `VerticalZoomedSurface`).
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
                onFirstPage: { goToFirstPage() },
                onLastPage: { goToLastPage() },
                onSwipeChanged: { translationX in
                    onSwipeChanged(translationX: translationX, viewportWidth: viewport.width)
                },
                onSwipeEnded: { translationX, predictedEndX, velocityX in
                    onSwipeEnded(
                        translationX: translationX,
                        predictedEndX: predictedEndX,
                        velocityX: velocityX,
                        viewportWidth: viewport.width,
                    )
                },
                showsHint: !pageTapHintDismissed,
                onAnyZoneTouchDown: { pageTapHintDismissed = true },
            )
        }
        // Full-bleed so pinch zoom can stretch the page band beyond the safe area into the chrome regions. The hosted
        // surface re-applies `pageInsets` as padding so the band sits inside the safe area at zoom 1.
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
                pinch.magnification = 1.0
                pinch.anchor = .center
                pinch.offsetX = 0
                pinch.offsetY = 0
            }
        }
    }

    private func followCursor(_ cursor: ScoreCursor?) {
        guard !pageState.isDragging else { return }
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
        jumpToPage(at: pageState.pageIndex + delta)
    }

    private func goToFirstPage() {
        jumpToPage(at: 0)
    }

    private func goToLastPage() {
        jumpToPage(at: pages.count - 1)
    }

    /// Resets the pinch / zoom state and animates to `target` if it is in range and not already the current page.
    /// Shared by the delta-based prev / next zones and the jump-to-edge zones.
    private func jumpToPage(at target: Int) {
        guard target >= 0, target < pages.count else { return }
        guard target != pageState.pageIndex else { return }
        viewModel.resetZoom()
        committedZoom = 1.0
        pinch.magnification = 1.0
        pinch.anchor = .center
        pinch.offsetX = 0
        pinch.offsetY = 0
        commitPageTurn(to: target)
    }

    /// Drive the page turn by mutating `pageIndex` inside `withAnimation`. `PagedZoomedSurface` keeps the adjacent
    /// pages pre-rendered, and every page's `.offset` is a pure function of its index vs the current one — so a single
    /// `pageIndex` change makes the moving side interpolate while the static side stays put. No `slideProgress`, no
    /// outgoing tracking, no run-loop hop.
    ///
    /// Jumps that involve idx 0 (jump-to-first or jump-from-first) flip `pageState.freezeFirstPageOffset` so idx 0
    /// stays pinned at `offset 0` for the duration of the animation. Otherwise idx 0 would slide between
    /// `-viewport.width` (its always-rule non-slide resting position) and `0` (its current-page slide position), which
    /// reads as a sideways slide rather than the symmetric fade idx-last gets for free (idx-last's offset is `0` in
    /// every state). The flag is released in `completion:` so the static state can settle back to the always-rule while
    /// idx 0 is invisible (`opacity 0`).
    private func commitPageTurn(to target: Int) {
        let previous = pageState.pageIndex
        let isJump = abs(target - previous) > 1
        let involvesFirstPage = target == 0 || previous == 0
        let shouldFreeze = isJump && involvesFirstPage

        if shouldFreeze {
            pageState.freezeFirstPageOffset = true
        }
        withAnimation(Self.pageTransitionAnimation) {
            pageState.pageIndex = target
        } completion: {
            if shouldFreeze {
                pageState.freezeFirstPageOffset = false
            }
        }
        // Reset scroll position to origin when the previous page was scrolled — typically the user was zoomed in
        // and scrolled around before tapping a navigation zone. Skipping this when `liveScrollOffset == .zero`
        // avoids triggering `ScoreScrollHost.updateUIView` (whose `layoutIfNeeded()` passes can cost tens of ms)
        // for the common zoom-1 case where the scroll position is already at origin.
        if liveScrollOffset != .zero {
            pendingScroll = .immediate(.zero)
        }
    }

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

    /// Live drag → `dragTranslationX`. Applies rubber-band damping on the impossible-commit side. If a drag is in
    /// progress (`isDragging`) and the gate flips false mid-gesture — typically because a second finger landed and
    /// started a pinch — treat the drag as cancelled: clear the flag and animate the band back to rest. A
    /// subsequent `.onEnded` then no-ops via the `isDragging` guard in `onSwipeEnded`.
    private func onSwipeChanged(
        translationX: CGFloat,
        viewportWidth: CGFloat,
    ) {
        guard pageSwipeEnabled else {
            if pageState.isDragging {
                pageState.isDragging = false
                swipeStartCursor = nil
                withAnimation(Self.cancelAnimation(
                    snapBackDistance: pageState.dragTranslationX,
                    viewportWidth: viewportWidth,
                )) {
                    pageState.dragTranslationX = 0
                }
            }
            return
        }
        if !pageState.isDragging {
            swipeStartCursor = playbackCursor
        }
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
    /// `commitPageTurn` animation; cancel snaps back with a shorter curve. Either way, `isDragging` clears and —
    /// only when the playback cursor actually advanced during the gesture — `followCursor` re-runs so the page
    /// catches up to active playback. A static cursor (paused playback) leaves the user's swipe destination alone.
    private func onSwipeEnded(
        translationX: CGFloat,
        predictedEndX: CGFloat,
        velocityX: CGFloat,
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
        let cursorAdvancedDuringSwipe = playbackCursor != swipeStartCursor
        swipeStartCursor = nil

        switch outcome {
        case .commitNext:
            commitDragTurn(
                to: pageState.pageIndex + 1,
                velocityX: velocityX, viewportWidth: viewportWidth,
            )
        case .commitPrevious:
            commitDragTurn(
                to: pageState.pageIndex - 1,
                velocityX: velocityX, viewportWidth: viewportWidth,
            )
        case .cancel:
            withAnimation(Self.cancelAnimation(
                snapBackDistance: pageState.dragTranslationX,
                viewportWidth: viewportWidth,
            )) {
                pageState.dragTranslationX = 0
            }
        }

        if cursorAdvancedDuringSwipe {
            followCursor(playbackCursor)
        }
    }

    /// Drag-commit variant of `commitPageTurn`. Difference: mutates `pageIndex` and `dragTranslationX` inside the
    /// same `withAnimation` block so every page interpolates from "old baseline + drag" to "new baseline + 0" as
    /// one motion. No freeze-first-page handling — drag commits are always ±1, never jump-to-edge.
    ///
    /// The animation duration is derived from the release `velocityX` so a fast flick completes quickly while a
    /// slow release falls back to the original `pageTransitionMaxDuration` feel.
    private func commitDragTurn(to target: Int, velocityX: CGFloat, viewportWidth: CGFloat) {
        guard target >= 0, target < pages.count else {
            withAnimation(Self.cancelAnimation(
                snapBackDistance: pageState.dragTranslationX,
                viewportWidth: viewportWidth,
            )) {
                pageState.dragTranslationX = 0
            }
            return
        }
        let remaining = max(0, viewportWidth - abs(pageState.dragTranslationX))
        let animation = Self.commitAnimation(
            remainingDistance: remaining,
            velocityMagnitude: abs(velocityX),
            viewportWidth: viewportWidth,
        )
        withAnimation(animation) {
            pageState.pageIndex = target
            pageState.dragTranslationX = 0
        }
        pendingScroll = .immediate(.zero)
    }

    /// Cap on the commit animation duration. Matches the original fixed `pageTransitionAnimation` length so a slow
    /// release feels identical to the tap-based page turn — the user only sees a faster transition when they
    /// actually flicked the page.
    private static let commitMaxDuration = 0.22
    /// Floor on the commit animation duration. Prevents an aggressive flick from completing so quickly that the
    /// motion is hard to follow.
    private static let commitMinDuration = 0.10
    /// Cap on the cancel animation duration. Matches the original snap-back length so a near-threshold cancel
    /// (large `dragTranslationX`) still settles in the familiar time.
    private static let cancelMaxDuration = 0.18
    /// Floor on the cancel animation duration. A 50 pt snap-back at the proportional rate would otherwise be
    /// nearly invisible.
    private static let cancelMinDuration = 0.08

    /// Commit animation whose duration matches the release velocity. The baseline speed (`viewportWidth /
    /// commitMaxDuration`) acts as a floor on velocity, so slow releases use the same speed as the tap-based
    /// page-turn animation; flick releases use their own (higher) speed, with the result clamped between
    /// `commitMinDuration` and `commitMaxDuration`.
    static func commitAnimation(
        remainingDistance: CGFloat,
        velocityMagnitude: CGFloat,
        viewportWidth: CGFloat,
    ) -> Animation {
        guard viewportWidth > 0, remainingDistance > 0 else {
            return .easeOut(duration: commitMaxDuration)
        }
        let baselineSpeed = Double(viewportWidth) / commitMaxDuration
        let speed = max(Double(velocityMagnitude), baselineSpeed)
        let raw = Double(remainingDistance) / speed
        let duration = min(commitMaxDuration, max(commitMinDuration, raw))
        return .easeOut(duration: duration)
    }

    /// Cancel animation whose duration scales with the snap-back distance. Pure distance-proportional with floor
    /// and ceiling — velocity is not folded in because a cancel almost always means "the user backed off", so the
    /// release speed is small or even reverses direction. Larger snap distances get the full `cancelMaxDuration`;
    /// smaller ones settle faster down to `cancelMinDuration`.
    static func cancelAnimation(
        snapBackDistance: CGFloat,
        viewportWidth: CGFloat,
    ) -> Animation {
        guard viewportWidth > 0 else {
            return .smooth(duration: cancelMaxDuration)
        }
        let progress = min(max(Double(abs(snapBackDistance)) / Double(viewportWidth), 0), 1)
        let raw = progress * cancelMaxDuration
        let duration = min(cancelMaxDuration, max(cancelMinDuration, raw))
        return .smooth(duration: duration)
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

    /// Greedy paginator working in document-Y coordinates. Walks `systems` in order and closes the current page just
    /// before a system whose bottom edge would extend past `pageTopDoc + pageHeight`. `pageTopDoc` is `0` for the first
    /// page (so the title frame and any pre-system decorations are visible) and the previous page's last-system bottom
    /// for every subsequent page (so the gap region above the new page's first system — which is where rehearsal marks
    /// live — renders on the new page, not the previous one).
    ///
    /// Authored `<LayoutBreak>page` on a system's last measure closes the page immediately under `.honor` /
    /// `.ignoreSystemBreaks`; `.ignoreAll` lets pages keep packing until vertical overflow.
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

/// Reads `pageState.dragTranslationX` in isolation and applies it as a horizontal `.offset` on `content`. This is the
/// only place that touches `dragTranslationX` during rendering — moving the read out of `PagedZoomedSurface.body`
/// stops the whole surface from re-evaluating on every gesture sample, leaving only this modifier's body to recompute
/// while the finger is moving.
private struct BandDragOffset: ViewModifier {
    let pageState: PageState

    func body(content: Content) -> some View {
        content.offset(x: pageState.dragTranslationX)
    }
}

private struct PagedZoomedSurface: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    /// Observed directly so the parent's `withAnimation` on `pageIndex` reaches this subtree via observation — the
    /// `UIHostingController` boundary swallows animation transactions delivered through `rootView` reassignment, which
    /// would make the turn snap if we passed `pageIndex` by parameter.
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
    let onFirstPage: () -> Void
    let onLastPage: () -> Void
    let onSwipeChanged: (CGFloat) -> Void
    /// `(translationX, predictedEndX, velocityX)` — finger lift values forwarded to the container's
    /// `onSwipeEnded`. `velocityX` is `DragGesture.Value.velocity.width` (pt/s) at release.
    let onSwipeEnded: (CGFloat, CGFloat, CGFloat) -> Void
    let showsHint: Bool
    let onAnyZoneTouchDown: () -> Void

    var body: some View {
        if let doc = document, !pages.isEmpty {
            let zoom = viewModel.viewportZoom
            let paddedWidth = viewport.width + pageInsets.leading + pageInsets.trailing
            let paddedHeight = viewport.height + pageInsets.top + pageInsets.bottom
            let framedWidth = paddedWidth * zoom
            let framedHeight = paddedHeight * zoom
            let currentIdx = min(max(pageState.pageIndex, 0), pages.count - 1)
            // Keep both neighbors pre-rendered so a page turn never has to spin up a fresh `ScoreView` at tap time —
            // the pages already exist in the tree, only their offsets animate. Three-way baseline: `idx < currentIdx`
            // sits at `-viewport.width` (off-screen leading), `idx == currentIdx` at `0`, `idx > currentIdx` at
            // `+viewport.width` (off-screen trailing). The live finger translation is applied band-wide one level up
            // (`.offset(x: pageState.dragTranslationX)` on the enclosing ZStack), so the whole strip slides as one
            // compositing transform rather than `N` per-page offset updates. `zIndex = -Double(idx)` still keeps
            // lower indices on top — irrelevant during the slide (pages don't overlap) but used when drag-following
            // pushes a sub-pixel sliver past zero.
            let slideSet = Set([-1, 0, 1].compactMap { delta -> Int? in
                let idx = currentIdx + delta
                return (0 ..< pages.count).contains(idx) ? idx : nil
            })
            // First / last are kept resident outside the slide window at `opacity 0` so jump-to-edge taps don't pay the
            // `ScoreView` build cost. They animate via opacity (under the same `withAnimation` transaction that drives
            // the slide), which reads as a fade — the only sensible animation when the source and target are
            // non-adjacent.
            let edgeSet: Set<Int> = pages.isEmpty
                ? []
                : [0, pages.count - 1]
            let windowIndices = slideSet.union(edgeSet).sorted()

            ZStack(alignment: .topLeading) {
                // Page band — clipped to viewport and inset by `pageInsets` so the music sits inside the safe area +
                // overlay reserve. Tap zones live outside this wrapper so they can still reach the host's edges (see
                // below).
                ZStack(alignment: .topLeading) {
                    ForEach(windowIndices, id: \.self) { idx in
                        let inSlideWindow = slideSet.contains(idx)
                        // Three-way baseline (was two-way `< current` / `>= current`). Now the page after current sits
                        // off-screen *trailing* at `+viewport.width` so a leftward drag can reveal it; previous still
                        // sits off-screen leading at `-viewport.width`. `freezeFirstPageOffset` overrides idx 0 to hold
                        // at `0` during jump-from / jump-to-first transitions, same as before.
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
                            // Per-page offset is the pure `pageIndex`-derived baseline (`< current` →
                            // `-viewport.width`, `== current` → `0`, `> current` → `+viewport.width`). The live
                            // finger translation is applied once at the band level below — applying it per-page
                            // would force `N` individual `.offset` mutations per gesture sample, which the SwiftUI
                            // layout pass cannot keep up with on a 120 Hz device. Pinch follows the same model
                            // (single `.scaleEffect` / `.offset` at the outer surface).
                            //
                            // For jumps that involve idx 0 the container raises `freezeFirstPageOffset` so idx 0
                            // holds at `0` for the duration — jump-to-first then fades in at center (like
                            // jump-to-last) instead of sliding rightward from `-viewport.width`.
                                .offset(x: frozenFirstPage ? 0 : baseOffset)
                                .opacity(inSlideWindow ? 1 : 0)
                                .allowsHitTesting(inSlideWindow)
                                // Subtracting `pages.count` for non-slide entries pushes every resident edge page below
                                // every slide page, so the opacity crossfade is hidden beneath whichever slide page
                                // covers the same band region.
                                .zIndex(
                                    inSlideWindow
                                        ? -Double(idx)
                                        : -Double(idx) - Double(pages.count),
                                )
                                // Removed pages disappear instantly (no default `.opacity` fade-out at their old
                                // zIndex). Inserted pages fade in via opacity so a fresh slide-next page (e.g. idx 1
                                // entering at cur = 0 during jump-to-first) doesn't pop in at full opacity on top of
                                // the still-fading target.
                                .transition(
                                    .asymmetric(
                                        insertion: .opacity,
                                        removal: .identity,
                                    ),
                                )
                    }
                }
                // Live drag translation applied once for the whole band — every page slides together as a
                // compositing-level transform, the same pattern pinch uses. `.offset` does not affect layout, so
                // the outer `.frame` + `.clipped()` below still clip to the fixed band rectangle while the
                // contents slide through it.
                //
                // The read of `dragTranslationX` is isolated inside `BandDragOffset` so the enclosing
                // `PagedZoomedSurface.body` does not invalidate on every drag sample — only the modifier's tiny
                // body re-evaluates, the ForEach / ScoreView subtree stays intact.
                .modifier(BandDragOffset(pageState: pageState))
                // Clip neighbors to the page band. Without this, the pre-rendered previous page (offset
                // `-viewport.width`) leaks out the leading side whenever the band does not fully cover the host (pinch
                // zoom-out below 100 % and landscape orientations where `pageInsets.leading` adds a safe-area gap to
                // the left of the band).
                .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
                .clipped()
                .padding(pageInsets)
                // Single band-level swipe gesture (was previously attached per-page inside `scoreSurface`,
                // which spawned one `DragGesture` per resident page — up to five concurrent recognizers, all
                // firing onChanged from their own activation reference, producing oscillating `dragTranslationX`
                // values and visible jitter). `minimumDistance: 8` lets a tap below the threshold still reach the
                // per-page `tapSeekGesture` inside the ScoreView; crossing 8 pt activates the swipe and the
                // tap-seek's `SpatialTapGesture` is rejected on release (high travel).
                //
                // Above unit zoom the swipe is masked off (`.subviews`) so the hosting `UIScrollView`'s pan
                // recogniser can claim the touch and handle one-finger panning of the zoomed score. Tap-seek
                // (on the score subview) is unaffected by the mask.
                .simultaneousGesture(
                    pageSwipeGesture(),
                    including: abs(zoom - 1.0) < 0.001 ? .all : .subviews,
                )

                // Tap zones extend `pageInsets.leading` / `pageInsets.trailing` outward so the tap-active (and visually
                // highlighted) area reaches the host's edges in landscape, where there is otherwise a safe-area gutter
                // that would swallow edge taps. The vertical padding matches the page band's so the overlay stays
                // aligned with the music vertically.
                tapOverlay()
                    .padding(.top, pageInsets.top)
                    .padding(.bottom, pageInsets.bottom)
            }
            .scaleEffect(pinch.magnification, anchor: pinch.anchor)
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: pinch.offsetX, y: pinch.offsetY)
            .frame(
                width: framedWidth,
                height: framedHeight,
                alignment: .topLeading,
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
        // Start the clip from the previous page's last-system bottom (or `0` for the first page) so the gap above the
        // current page's first system — where rehearsal marks sit, plus the title frame on page 0 — renders here rather
        // than on the previous page.
        let pageStartY = PagedZoomedSurface.pageStartY(
            forPage: idx, pages: pages, doc: doc,
        )
        let pageEndY: CGFloat = (0 ..< doc.systems.count).contains(lastSystemIndex)
            ? doc.systems[lastSystemIndex].origin.y
            + doc.systems[lastSystemIndex].size.height
            : pageStartY
        let pageHeight = max(0, pageEndY - pageStartY)
        // Sub-document containing only this page's systems — each ScoreView in the slide window otherwise constructs
        // a `SystemLayerView` for every system in the full doc, multiplying the layout cost by `windowIndices.count`
        // (up to 5). System `origin.y` is preserved so the existing `.offset(y: -pageStartY)` + outer `.clipped()`
        // machinery still positions the page correctly inside the band. `titleFrame` is preserved only on idx 0.
        let pageSystems = Array(doc.systems[pageRange])
        let pageDoc = LayoutDocument(
            size: doc.size,
            systems: pageSystems,
            metrics: doc.metrics,
            titleFrame: idx == 0 ? doc.titleFrame : nil,
        )
        return scoreSurface(
            document: pageDoc,
            pageStartY: pageStartY,
            pageHeight: pageHeight,
        )
        // Inset the score by the shared horizontal gutter so the page background still spans the full band but the
        // music itself sits inboard. The layout uses the same gutter-deducted width, so the score wraps to fit inside.
        .padding(.horizontal, PagedScoreContainer.horizontalContentPadding)
            // White fills the full viewport so any unused space beneath the last system on this page reads as part of
            // the page (just like `SheetMusicUI.PagedScoreView`'s canvas) rather than the host scroll background.
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
            .gesture(tapSeekGesture(
                document: doc, pageStartY: pageStartY, pageHeight: pageHeight,
            ))
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
        // `.topLeading` (not `.top`) prevents the default `.center` horizontal alignment from drifting the doc when
        // `doc.size.width` ≠ inner width — which would clip part-labels on the leading edge (e.g. "Lead" → "ead").
        .frame(
            width: viewport.width - PagedScoreContainer.horizontalContentPadding * 2,
            height: pageHeight,
            alignment: .topLeading,
        )
        .clipped()
    }

    private func tapOverlay() -> some View {
        TapOverlay(
            viewport: viewport,
            leadingExtra: pageInsets.leading,
            trailingExtra: pageInsets.trailing,
            onFirstPage: onFirstPage,
            onPrevPage: onPrevPage,
            onLastPage: onLastPage,
            onNextPage: onNextPage,
            currentPageNumber: pageState.pageIndex + 1,
            totalPages: pages.count,
            showsHint: showsHint,
            onAnyZoneTouchDown: onAnyZoneTouchDown,
        )
    }

    private func tapSeekGesture(
        document: LayoutDocument,
        pageStartY: CGFloat,
        pageHeight: CGFloat,
    ) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named("scoreSurface"))
            .onEnded { value in
                // The named coordinate space spans the full doc (the inner `ScoreView` is `doc.size.height` tall and
                // the wrapper offsets it up by `pageStartY`). The outer `.clipped()` clips rendering but not hit
                // testing, so a tap on the blank band beneath the last visible system still resolves to a y that lives
                // on the next page. Without this guard, `nearestCursor` would return that next-page system, the
                // resulting `setManualCursor` would mutate `playbackCursor`, and `followCursor` would auto-turn to the
                // next page — the user perceives this as the page advancing whenever they tap the lower screen area.
                let pageEndY = pageStartY + pageHeight
                guard value.location.y >= pageStartY,
                      value.location.y <= pageEndY else { return }
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.setManualCursor(cursor)
                lastManualCursor = cursor
            }
    }

    private func pageSwipeGesture() -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                // Per-sample horizontal-dominance gate: a sample whose vertical component dominates is ignored,
                // letting a future vertical-scroll surface (not present today) coexist without competing with the
                // page swipe. Pure-horizontal drags satisfy `abs(dy) == 0`, well below `abs(dx) / 1.5`.
                guard abs(value.translation.width)
                    > abs(value.translation.height) * 1.5
                else { return }
                onSwipeChanged(value.translation.width)
            }
            .onEnded { value in
                onSwipeEnded(
                    value.translation.width,
                    value.predictedEndTranslation.width,
                    value.velocity.width,
                )
            }
    }

    /// First page renders from doc-Y `0` (so the title frame and any pre-system decoration are visible); every
    /// subsequent page starts at the previous page's last-system bottom (so the gap above its own first system —
    /// rehearsal marks, etc. — lands on the right page).
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

/// Identifies the four page-navigation slices in `tapOverlay()` so each one can render the right icon / label combo
/// when pressed without duplicating that map at every caller.
private enum PageTapZoneKind {
    case first
    case last
    case previous
    case next

    /// `first` ships a custom symbol bundled with the Reader module (no system SF Symbol matches the
    /// `arrow.uturn.backward.to.line` glyph). Everything else maps to a system symbol.
    var image: Image {
        switch self {
        case .first: Image("arrow.uturn.backward.to.line", bundle: .module)
        case .last: Image(systemName: "arrow.forward.to.line")
        case .previous: Image(systemName: "arrow.uturn.backward")
        case .next: Image(systemName: "arrow.forward")
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .first: "reader.pageMode.tapZone.first"
        case .last: "reader.pageMode.tapZone.last"
        case .previous: "reader.pageMode.tapZone.previous"
        case .next: "reader.pageMode.tapZone.next"
        }
    }

    /// Per-corner radii for the highlight pill. The side that runs along the screen edge (leading for `first` /
    /// `previous`, trailing for `last` / `next`) stays square; the inner side rounds off so the highlight reads as a
    /// tab tucked against the edge rather than a free-floating chip.
    func cornerRadii(radius: CGFloat) -> RectangleCornerRadii {
        switch self {
        case .first, .previous:
            RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: radius,
                topTrailing: radius,
            )
        case .last, .next:
            RectangleCornerRadii(
                topLeading: radius,
                bottomLeading: radius,
                bottomTrailing: 0,
                topTrailing: 0,
            )
        }
    }
}

/// Page-turn tap zone that fires `action` on release inside the zone. `DragGesture(minimumDistance: 0)` drives press
/// tracking via `@GestureState` (auto-resets on lift/cancel) and decides whether the release counts as a tap by
/// checking the final location.
///
/// The highlight (translucent accent fill + icon + label) is driven by the externally-supplied `highlighted` flag, not
/// the zone's own gesture state. The parent collects press state from all zones and feeds the same flag back to each
/// one so a tap on any zone lights up the whole set in unison.
private struct PageTapZone: View {
    let kind: PageTapZoneKind
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void
    let highlighted: Bool
    /// When true, render the onboarding hint (dashed border + light accent fill + tinted icon/label). Mutually
    /// exclusive with `highlighted` — the moment a finger lands the parent flips `hintVisible` false and `highlighted`
    /// true.
    let hintVisible: Bool
    let onPressChange: (Bool) -> Void

    @GestureState private var isPressed = false

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: kind.cornerRadii(radius: 12))
        ZStack {
            // Onboarding hint layer: dashed border + light tint fill + tinted icon/label at full opacity.
            ZStack {
                shape.fill(Color.accentColor.opacity(0.12))
                shape.strokeBorder(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]),
                )
                zoneLabel
                    .foregroundStyle(Color.accentColor)
            }
            .opacity(hintVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: hintVisible)

            // Press-feedback layer: existing solid grey fill + white icon/label. Resident at full strength so rapid
            // re-taps can't stack a fading-out copy under a fading-in copy and darken the fill.
            ZStack {
                shape.fill(Color.secondary.opacity(0.5))
                zoneLabel
                    .foregroundStyle(.white)
            }
            .opacity(highlighted ? 1 : 0)
            // Fade the highlight out on release; show it immediately on touch. Picking the animation off the *new*
            // value of `highlighted` keeps appearance instant (nil animation) and disappearance smooth. The
            // `delay(0.35)` keeps the highlight visible after the page has already turned, so the user can see *which*
            // tap zone fired before it disappears.
            .animation(
                highlighted ? nil : .easeOut(duration: 0.3).delay(0.35),
                value: highlighted,
            )
        }
        .frame(width: width, height: height)
        // Hit area stays a full rectangle so the square (screen-edge) corners remain tappable even though the pill
        // crops them visually.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
                .onEnded { value in
                    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                    if bounds.contains(value.location) { action() }
                },
        )
        .onChange(of: isPressed) { _, new in onPressChange(new) }
    }

    private var zoneLabel: some View {
        VStack(spacing: 6) {
            kind.image
                .font(.title2)
                .bold()
            Text(kind.labelKey, bundle: .module)
                .font(.caption)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

/// Four-zone page-navigation overlay used by `PagedZoomedSurface`. Owns the shared press state so any active touch
/// lights up every zone in unison — that uniform highlight is the real surface the preview at the bottom of this file
/// exercises.
///
/// `leadingExtra` / `trailingExtra` widen the leading / trailing columns outward so the tap-active (and visually
/// highlighted) area can reach beyond `viewport` to the host's edges. The page-band internals still anchor to
/// `viewport`; only the edge columns absorb the safe-area gutters.
private struct TapOverlay: View {
    let viewport: CGSize
    let leadingExtra: CGFloat
    let trailingExtra: CGFloat
    let onFirstPage: () -> Void
    let onPrevPage: () -> Void
    let onLastPage: () -> Void
    let onNextPage: () -> Void
    /// 1-indexed page number shown in the indicator badge.
    let currentPageNumber: Int
    /// Total page count shown in the indicator badge.
    let totalPages: Int
    /// When true, the four zones render a dashed-border onboarding hint at rest. Flips false the moment the user
    /// touches any zone.
    let showsHint: Bool
    /// Fires once per touch-down sequence — the parent uses this to flip the persisted dismiss flag.
    let onAnyZoneTouchDown: () -> Void

    /// Per-zone press state. Set element identifies which zone is touched; emptiness drives the global highlight off.
    /// Seeded from `initialPressedKinds` so previews can render the highlighted layout without firing a real gesture.
    @State private var pressedKinds: Set<PageTapZoneKind>

    init(
        viewport: CGSize,
        leadingExtra: CGFloat = 0,
        trailingExtra: CGFloat = 0,
        onFirstPage: @escaping () -> Void,
        onPrevPage: @escaping () -> Void,
        onLastPage: @escaping () -> Void,
        onNextPage: @escaping () -> Void,
        currentPageNumber: Int = 1,
        totalPages: Int = 1,
        showsHint: Bool = false,
        onAnyZoneTouchDown: @escaping () -> Void = {},
        initialPressedKinds: Set<PageTapZoneKind> = [],
    ) {
        self.viewport = viewport
        self.leadingExtra = leadingExtra
        self.trailingExtra = trailingExtra
        self.onFirstPage = onFirstPage
        self.onPrevPage = onPrevPage
        self.onLastPage = onLastPage
        self.onNextPage = onNextPage
        self.currentPageNumber = currentPageNumber
        self.totalPages = totalPages
        self.showsHint = showsHint
        self.onAnyZoneTouchDown = onAnyZoneTouchDown
        _pressedKinds = State(initialValue: initialPressedKinds)
    }

    var body: some View {
        let baseColumnWidth = viewport.width * 0.12
        let leadingColumnWidth = baseColumnWidth + leadingExtra
        let trailingColumnWidth = baseColumnWidth + trailingExtra
        let middleWidth = viewport.width * 0.76
        let totalWidth = viewport.width + leadingExtra + trailingExtra
        let topHeight = viewport.height * 0.3
        let bottomHeight = viewport.height - topHeight
        let highlighted = !pressedKinds.isEmpty
        // Hint is mutually exclusive with the press visual: the moment a finger lands, `pressedKinds` is non-empty and
        // `hintVisible` flips false so the hint fades out while the press fill takes over.
        let hintVisible = showsHint && pressedKinds.isEmpty
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                edgeColumn(
                    width: leadingColumnWidth,
                    topHeight: topHeight,
                    bottomHeight: bottomHeight,
                    topKind: .first,
                    bottomKind: .previous,
                    topAction: onFirstPage,
                    bottomAction: onPrevPage,
                    highlighted: highlighted,
                    hintVisible: hintVisible,
                )
                Color.clear
                    .frame(width: middleWidth)
                    .allowsHitTesting(false)
                edgeColumn(
                    width: trailingColumnWidth,
                    topHeight: topHeight,
                    bottomHeight: bottomHeight,
                    topKind: .last,
                    bottomKind: .next,
                    topAction: onLastPage,
                    bottomAction: onNextPage,
                    highlighted: highlighted,
                    hintVisible: hintVisible,
                )
            }

            // Capsule badge that mirrors the tap-zone highlight: same accent fill / opacity, same instant-on / fade-off
            // animation, displaying the 1-indexed page position.
            //
            // Kept resident (opacity-gated rather than `if`-gated) so its `current` updates while it's still visible —
            // the page index changes the moment the finger lifts, but the badge stays on screen through the delay
            // window, and we want the number it shows to be the *new* page from t=0 instead of the previous value
            // frozen with the removed view.
            PageIndicatorBadge(
                current: currentPageNumber,
                total: totalPages,
            )
            .padding(.bottom, 24)
            .opacity(highlighted ? 1 : 0)
            .allowsHitTesting(false)
        }
        .frame(width: totalWidth, height: viewport.height, alignment: .topLeading)
        // Local `.animation` only covers what doesn't already carry its own — i.e. the badge's insert / remove
        // transition. Each `PageTapZone` has its own `.animation(_:value:)` so its highlight is still governed by the
        // closer modifier. The delay matches the tap-zone fade-out so the indicator disappears in sync.
        .animation(
            highlighted ? nil : .easeOut(duration: 0.3).delay(0.35),
            value: highlighted,
        )
    }

    /// One leading / trailing tap column split 3 : 7 vertically. The top slice jumps to the first / last page; the
    /// bottom slice turns one page in the same direction.
    private func edgeColumn(
        width: CGFloat,
        topHeight: CGFloat,
        bottomHeight: CGFloat,
        topKind: PageTapZoneKind,
        bottomKind: PageTapZoneKind,
        topAction: @escaping () -> Void,
        bottomAction: @escaping () -> Void,
        highlighted: Bool,
        hintVisible: Bool,
    ) -> some View {
        VStack(spacing: 8) {
            PageTapZone(
                kind: topKind,
                width: width,
                height: topHeight,
                action: topAction,
                highlighted: highlighted,
                hintVisible: hintVisible,
                onPressChange: { updatePressed(topKind, pressed: $0) },
            )
            PageTapZone(
                kind: bottomKind,
                width: width,
                height: bottomHeight,
                action: bottomAction,
                highlighted: highlighted,
                hintVisible: hintVisible,
                onPressChange: { updatePressed(bottomKind, pressed: $0) },
            )
        }
    }

    /// Fires `onAnyZoneTouchDown` exactly once per touch-down sequence — the first transition from "no zones pressed"
    /// to "any zone pressed". A long press or a finger-roll between zones does not refire.
    private func updatePressed(_ kind: PageTapZoneKind, pressed: Bool) {
        if pressed {
            if pressedKinds.isEmpty { onAnyZoneTouchDown() }
            pressedKinds.insert(kind)
        } else {
            pressedKinds.remove(kind)
        }
    }
}

/// `n / d` page-position pill shown at the bottom of the page band while a tap zone is held. Matches the tap-zone
/// highlight fill so the navigation feedback reads as one piece.
private struct PageIndicatorBadge: View {
    let current: Int
    let total: Int

    var body: some View {
        Text(verbatim: "\(current) / \(total)")
            .font(.subheadline.monospacedDigit())
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.46)))
    }
}

// Renders the production `TapOverlay` with its highlight state pre-seeded so every zone shows its icon + label. Iterate
// on the real view here — anything tweaked in `PageTapZone` / `PageTapZoneKind` shows up directly. The page band is
// sampled from the actual device canvas via `GeometryReader` so the tap zones really do start at the device's leading /
// trailing edge. Set `leadingGutter` / `trailingGutter` to mock the safe-area gutters that `pageInsets` contributes in
// landscape.
#Preview("Tap zones · no gutters") {
    TapZonePreviewHost(leadingGutter: 0, trailingGutter: 0)
        .ignoresSafeArea()
}

#Preview("Tap zones · landscape gutters") {
    TapZonePreviewHost(leadingGutter: 59, trailingGutter: 59)
        .ignoresSafeArea()
}

#Preview("Tap zones · onboarding hint") {
    TapZonePreviewHost(leadingGutter: 0, trailingGutter: 0, showsHint: true)
        .ignoresSafeArea()
}

private struct TapZonePreviewHost: View {
    let leadingGutter: CGFloat
    let trailingGutter: CGFloat
    /// When true, render the onboarding hint at rest (no pressed zones). Mutually exclusive with the highlighted
    /// press state — pressing a zone would dismiss the hint in production.
    var showsHint = false

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let viewportWidth = max(totalWidth - leadingGutter - trailingGutter, 0)
            let viewport = CGSize(width: viewportWidth, height: proxy.size.height)
            ZStack(alignment: .topLeading) {
                // Stripes mark where the safe-area gutters fall so it's visible that the tap zones overlap them.
                HStack(spacing: 0) {
                    Color.gray.opacity(0.25)
                        .frame(width: leadingGutter)
                    Color.white
                        .frame(width: viewportWidth)
                    Color.gray.opacity(0.25)
                        .frame(width: trailingGutter)
                }
                TapOverlay(
                    viewport: viewport,
                    leadingExtra: leadingGutter,
                    trailingExtra: trailingGutter,
                    onFirstPage: {},
                    onPrevPage: {},
                    onLastPage: {},
                    onNextPage: {},
                    showsHint: showsHint,
                    initialPressedKinds: showsHint ? [] : [.first],
                )
            }
        }
    }
}
