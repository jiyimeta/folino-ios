// PARITY(macos): vertical reader extras — the Mac container renders and scrolls the score and draws committed ink,
//   and nothing else. Pinch zoom (`PinchState` / `ScoreScrollHost`), the live annotation canvas, and the note-editing
//   overlay all live in the iOS `VerticalScoreContainer`'s UIKit-hosted subtree and have no Mac equivalent yet —
//   PencilKit ships no `PKCanvasView` on macOS at all, so annotation input needs a drawing surface of its own.

#if os(macOS)
import Domain
import PencilKit
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// The Mac's vertical-mode score viewport: a plain SwiftUI `ScrollView` over one `ScoreView`, with the engraved
/// `LayoutDocument` rebuilt off-main whenever the score, the staff size, or the viewport width changes.
///
/// **Pure SwiftUI, no AppKit host.** That is exactly why vertical goes first on the Mac: iOS needs `ScoreScrollHost`
/// because it drives pinch zoom through a `UIScrollView`, and the Mac has neither yet. Adapted from
/// swift-sheet-music's own macOS example container (`Examples/Apple/SheetMusicExample/macOS`), driven by folino's
/// `ReaderViewModel` instead of the example's local state.
///
/// **The playback cursor arrives as a value, not as a read.** `MacScoreContentView` is the view that reads
/// `playbackSession.displayCursor` / `.scrollAnchorCursor`, so a cursor tick re-renders this container and the leaf
/// below it — never `MacReaderRootScreen`. Same boundary the iOS `ScoreContentView` draws, and for the same reason:
/// a per-tick read at the root rebuilds the whole screen sixty times a second.
struct MacVerticalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let showAllMeasureNumbers: Bool
    /// The highlight cursor. Handed straight to the leaf surface; this view never reads it off the view model.
    let playbackCursor: ScoreCursor?
    /// Lookahead anchor used for auto-scroll ONLY — a cursor a couple of beats ahead of `playbackCursor` during
    /// playback. `nil` when not playing / scrubbing, in which case follow falls back to `playbackCursor`.
    let scrollAnchorCursor: ScoreCursor?
    /// User opt-out: when false, continuous playback no longer auto-scrolls. Manual navigation still keeps its
    /// target in view (see `readerShouldFollowPlayback`).
    let autoFollowEnabled: Bool
    /// Transpose offset in semitones. Only used to invalidate the layout cache via `MacVerticalLayoutKey` — the score
    /// passed in is already transposed.
    let transposeSemitones: Int
    let viewModel: ReaderViewModel

    /// Layout output — observable, not `@State`; see `ScoreLayoutState` for why an async relayout stored in `@State`
    /// does not re-run the body that reads it.
    @State private var layoutState = ScoreLayoutState()
    /// Off-main engraver holding this surface's incremental `LayoutCache`; see `ScoreRelayoutEngine`.
    @State private var relayoutEngine = ScoreRelayoutEngine()
    /// Committed ink, projected into the current layout's document space once per layout (and once per change to the
    /// stored layer) rather than per playback tick. See `MacInkProjection`.
    @State private var inkProjection = MacInkProjection()
    /// Programmatic scroll target for playback follow. `ScrollPosition.scrollTo(y:)` is the macOS 15 equivalent of the
    /// iOS container's `ScoreScrollCommand` — the same content-space offset, without a `UIScrollView` to drive.
    @State private var scrollPosition = ScrollPosition()
    /// The live vertical content offset, mirrored out of `ScrollGeometry` so the follow math can ask "is the playing
    /// system already visible?" without moving the scroll view.
    @State private var scrollOffsetY: CGFloat = 0

    /// Vertical breathing room above the first system and below the last, inside the scaled content so it tracks zoom.
    /// The Mac reader has no top chrome and no floating transport to clear yet, so one symmetric margin is all the
    /// padding there is (the iOS container reserves `topChromeInset` + the transport's clearance instead).
    private static let verticalPadding: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            scoreScroll(viewport: proxy.size)
        }
    }

    private func scoreScroll(viewport: CGSize) -> some View {
        let inset = horizontalInset(viewportWidth: viewport.width)
        let layoutWidth = max(viewport.width - inset * 2, staffSize * 4)
        return ScrollView(.vertical) {
            MacVerticalScoreSurface(
                viewModel: viewModel,
                document: layoutState.document,
                score: score,
                viewport: viewport,
                horizontalPadding: inset,
                verticalPadding: Self.verticalPadding,
                scoreOptions: scoreOptions,
                playbackCursor: playbackCursor,
                ink: inkProjection.drawing,
                scrollOffsetY: scrollOffsetY,
            )
        }
        // Vertical mode's ground is the paper: one continuous sheet, edge to edge, the way the iOS reader draws it,
        // and white in either appearance. See `MacReaderGround` for why Page mode gets an adaptive desk instead and
        // why vertical has no desk to adapt.
        //
        // **Only once there is something printed on it.** Before the first layout lands the surface shows a
        // `ProgressView`, and that spinner is the one thing in this reader that stands on paper and still resolves
        // against the system appearance — in dark mode it would draw light grey on white and all but vanish. Rather
        // than pin an appearance for one transient control, the paper waits: until then the spinner sits on the
        // window's own ground, which is exactly where `MacScoreContentView`'s `.loading` spinner sits a moment
        // earlier, so the two reads as one wait instead of two.
        .background(layoutState.document == nil ? Color.clear : MacReaderGround.paper)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            scrollOffsetY = newValue
        }
        .task(id: layoutKey(width: layoutWidth)) {
            await rebuildLayout(width: layoutWidth)
        }
        // The stored layer lands from `loadAnnotations()` a beat after the score, so the projection taken at the end
        // of the layout above can predate it. Re-projecting here is what makes ink that arrives late appear.
        .onChange(of: viewModel.annotationDrawings) { _, _ in
            projectInk(into: layoutState.document)
        }
        .onChange(of: [playbackCursor, scrollAnchorCursor]) { old, new in
            guard readerShouldFollowPlayback(
                autoFollowEnabled: autoFollowEnabled,
                isPlaybackDriven: scrollAnchorCursor != nil,
                cursorMoved: old[0] != new[0],
                followSuspended: viewModel.playbackSession.isPlaybackFollowSuspended,
            ) else { return }
            autoScroll(viewport: viewport)
        }
    }

    private func layoutKey(width: CGFloat) -> MacVerticalLayoutKey {
        MacVerticalLayoutKey(
            score: score,
            size: staffSize,
            width: width,
            honorLayoutBreaks: honorLayoutBreaks,
            collapseMultiMeasureRests: collapseMultiMeasureRests,
            showInvisibleElements: showInvisibleElements,
            showAllMeasureNumbers: showAllMeasureNumbers,
            transposeSemitones: transposeSemitones,
        )
    }

    /// Horizontal margin between the score and the window edge. Reuses the shared viewport arithmetic with the Mac's
    /// own idiom decision — `isPad: true`, because a Mac window is a large screen and wants the roomier margins, and
    /// because Page mode (a later task) draws its page band at the same inset.
    private func horizontalInset(viewportWidth: CGFloat) -> CGFloat {
        ReaderScoreLayout.scoreHorizontalInset(viewportWidth: viewportWidth, phoneDefault: 0, isPad: true)
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
            showsInvisibleElements: showInvisibleElements,
            measureNumbers: showAllMeasureNumbers ? .everyMeasure : .systemStart,
        )
    }

    private func rebuildLayout(width: CGFloat) async {
        let newDoc = await relayoutEngine.layout(
            score: score, options: scoreOptions, availableWidth: width,
        )
        guard !Task.isCancelled else { return }
        layoutState.document = newDoc
        projectInk(into: newDoc)
    }

    /// Place the stored ink in `document`'s coordinate space. Called from the relayout task and from the
    /// annotation-layer watcher — never from a body, and in particular never from `MacVerticalScoreSurface`, whose
    /// body re-runs on every playback tick. See `MacInkProjection`.
    private func projectInk(into document: LayoutDocument?) {
        guard let document else {
            inkProjection.drawing = PKDrawing()
            return
        }
        inkProjection.drawing = AnnotationAnchoring.display(
            viewModel.annotationDrawings, in: document,
            // Stored anchors are in source addressing; `document` is engraved from the staff-filtered score.
            staffFilter: .current(viewModel: viewModel, editingHost: nil),
        )
    }

    /// Playback follow, in the scroll content's own coordinate space. Identical policy to the iOS container: during
    /// playback the playing cursor's system is pinned near the top and only re-scrolled once it (or the lookahead a
    /// couple of beats ahead) leaves the viewport; paused / scrubbing falls back to a gentle keep-in-view. Both rules
    /// come from `Domain`'s shared implementations so iOS, Android and the Mac follow the cursor identically.
    private func autoScroll(viewport: CGSize) {
        guard let realCursor = playbackCursor, let doc = layoutState.document,
              let realRect = doc.cursorFrame(for: realCursor, in: score)
        else { return }

        let hPad = horizontalInset(viewportWidth: viewport.width)
        let zoom = macVerticalZoom(
            document: doc, viewportWidth: viewport.width,
            horizontalPadding: hPad, userZoom: viewModel.viewportZoom,
        )
        let pad = 8 * doc.metrics.sp * zoom
        let topPad = Self.verticalPadding
        let realMinY = (realRect.minY + topPad) * zoom
        let realMaxY = (realRect.maxY + topPad) * zoom
        let current = scrollOffsetY

        let target = if let lookaheadCursor = scrollAnchorCursor,
                        let lookRect = doc.cursorFrame(for: lookaheadCursor, in: score)
        {
            CGFloat(scrollOffsetPinningSystemTop(
                current: Double(current),
                systemMin: Double(realMinY),
                systemMax: Double(realMaxY),
                lookaheadMax: Double((lookRect.maxY + topPad) * zoom),
                viewport: Double(viewport.height),
                topInset: Double(topPad * zoom),
            ))
        } else {
            CGFloat(scrollOffsetKeepingInView(
                current: Double(current),
                targetMin: Double(realMinY),
                targetMax: Double(realMaxY),
                viewport: Double(viewport.height),
                pad: Double(pad),
            ))
        }

        guard abs(target - current) >= 0.5 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollPosition.scrollTo(y: target)
        }
    }
}

/// The score-drawing leaf. Everything that changes per playback tick is confined here: the parent container only
/// forwards the cursor, and `ScoreView` is the only thing that has to redraw when it moves.
struct MacVerticalScoreSurface: View {
    let viewModel: ReaderViewModel
    let document: LayoutDocument?
    let score: Score
    let viewport: CGSize
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let scoreOptions: ScoreViewOptions
    let playbackCursor: ScoreCursor?
    /// Committed ink, ALREADY projected into document space by the container. A value, never a projection run here —
    /// this body re-runs on every playback tick.
    let ink: PKDrawing
    /// Live scroll offset, used only to pick the band of ink worth rasterizing.
    let scrollOffsetY: CGFloat

    /// The name the tap-seek gesture reads its location in: the un-padded, un-scaled `ScoreView` frame, which is the
    /// `LayoutDocument`'s own coordinate space.
    private static let coordinateSpace = "macScoreSurface"

    var body: some View {
        if let doc = document {
            let zoom = macVerticalZoom(
                document: doc, viewportWidth: viewport.width,
                horizontalPadding: horizontalPadding, userZoom: viewModel.viewportZoom,
            )
            // The scroller knob is the one semantic element that rides on this reader's paper — AppKit draws the
            // overlay scroller inside the scroll view's frame, which vertical mode paints white edge to edge, so in
            // dark appearance a light knob would slide over white and vanish. Pinned here rather than at the screen
            // because it must not escape the scroll view; `MacScrollViewAppearance` states the argument. Inside the
            // `if let doc` branch on purpose: before the layout lands there is no paper, and the spinner below has to
            // keep the system appearance.
            scoreSurface(document: doc)
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, horizontalPadding)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(
                    width: (doc.size.width + horizontalPadding * 2) * zoom,
                    height: (doc.size.height + verticalPadding * 2) * zoom,
                    alignment: .topLeading,
                )
                .background(
                    MacScrollViewAppearance(appearance: .aqua)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false),
                )
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    private func scoreSurface(document doc: LayoutDocument) -> some View {
        ZStack(alignment: .topLeading) {
            ScoreView(
                document: doc, score: score, options: scoreOptions,
                playbackCursor: playbackCursor, playbackCursorColor: .accentColor.opacity(0.6),
            )
            .gesture(tapSeekGesture(document: doc))

            // Committed ink, read-only. Projected into this document's own space by the container (see
            // `MacInkProjection`), so a mark made on an iPad lands on the same note here whatever the Mac re-engraved
            // the score to. Above `ScoreView` (annotations are drawn over the notation) and below the loop overlays.
            //
            // Banded to what is on screen rather than to the whole document: on a long, heavily annotated score every
            // inked strip would otherwise rasterize at once. The band is snapped to the strip grid so scrolling does
            // not rebuild the raster on every frame — `MacScoreInkOverlay.scrollBand` states why.
            MacScoreInkOverlay(
                drawing: ink,
                surfaceSize: doc.size,
                band: inkBand(document: doc),
            )

            if viewModel.repeatModel.mode == .abLoop {
                LoopRegionOverlay(document: doc, range: viewModel.repeatModel.abRange)
                LoopBoundaryMarkers(
                    document: doc,
                    start: viewModel.repeatModel.pendingRepeatA,
                    end: viewModel.repeatModel.pendingRepeatB,
                )
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
    }

    /// The slice of document space the viewport currently shows, in the document's own coordinates.
    ///
    /// The surface is padded by `verticalPadding` and then scaled by `zoom`, so a content-space offset `y` sits at
    /// document `y / zoom - verticalPadding`. Snapping to the strip grid happens in `scrollBand`.
    private func inkBand(document doc: LayoutDocument) -> CGRect {
        let zoom = macVerticalZoom(
            document: doc, viewportWidth: viewport.width,
            horizontalPadding: horizontalPadding, userZoom: viewModel.viewportZoom,
        )
        guard zoom > 0 else { return CGRect(origin: .zero, size: doc.size) }
        return MacScoreInkOverlay.scrollBand(
            top: scrollOffsetY / zoom - verticalPadding,
            height: viewport.height / zoom,
            in: doc.size,
        )
    }

    /// Click-to-seek. With no playback controller wired on the Mac yet this still moves the displayed cursor —
    /// `ReaderPlaybackSession.setManualCursor` guards every `controller` call — so the click reads as a caret move
    /// rather than doing nothing at all.
    private func tapSeekGesture(document: LayoutDocument) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named(Self.coordinateSpace))
            .onEnded { value in
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.playbackSession.setManualCursor(cursor)
            }
    }
}

/// Fit-to-width factor times the user's zoom, so "zoom 1.0 = the whole system fits" regardless of what the engine's
/// right margin, spanners or ties added to `doc.size.width`. Free function rather than a method because the container
/// (for the follow math) and the leaf (for the render) must agree on it exactly.
private func macVerticalZoom(
    document doc: LayoutDocument,
    viewportWidth: CGFloat,
    horizontalPadding: CGFloat,
    userZoom: CGFloat,
) -> CGFloat {
    let framedContentWidth = doc.size.width + horizontalPadding * 2
    let fit = framedContentWidth > 0 ? min(1.0, viewportWidth / framedContentWidth) : 1.0
    return userZoom * fit
}

/// Identity for the `.task(id:)` that re-engraves the score. Mirrors the iOS container's `TaskKey` minus the editing
/// generation — the Mac reader has no edit session yet.
private struct MacVerticalLayoutKey: Hashable {
    let scoreSignature: Int
    let size: CGFloat
    let width: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let showAllMeasureNumbers: Bool
    let transposeSemitones: Int

    init(
        score: Score,
        size: CGFloat,
        width: CGFloat,
        honorLayoutBreaks: Bool,
        collapseMultiMeasureRests: Bool,
        showInvisibleElements: Bool,
        showAllMeasureNumbers: Bool,
        transposeSemitones: Int,
    ) {
        // `Score` is Equatable but not Hashable. Same cheap identity proxy the iOS container uses: structural shape
        // plus opening clefs, which is what makes a clef override re-trigger the task.
        scoreSignature = score.parts.count
            ^ (score.totalStaffCount << 8)
            ^ (score.division << 16)
            ^ score.openingClefSignature
            ^ (transposeSemitones << 24)
        self.size = size
        self.width = width
        self.honorLayoutBreaks = honorLayoutBreaks
        self.collapseMultiMeasureRests = collapseMultiMeasureRests
        self.showInvisibleElements = showInvisibleElements
        self.showAllMeasureNumbers = showAllMeasureNumbers
        self.transposeSemitones = transposeSemitones
    }
}
#endif
