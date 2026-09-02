// PARITY(macos): horizontal mode's live annotation canvas — the Mac strip renders, scrolls, edits the score and
//   carries the sticky pane; the live PencilKit canvas the iOS `HorizontalScoreContainer` hands its host has no
//   Mac form because PencilKit ships no `PKCanvasView` on macOS (Ⅴ).

#if os(macOS)
import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// The Mac's horizontal-mode score viewport: the score engraved at its natural width as one long strip inside the
/// magnifying `NSScrollView`, with a sticky pane pinned at the leading edge that takes over the part labels, the
/// bracket, and the active clef / key / time signature once the score has scrolled past its own.
///
/// **The sticky pane is the mode.** Continuous horizontal reading means the staff's identity — which instrument this
/// line is, what key it is in, what clef it carries — scrolls off the left edge within the first system and never
/// comes back. MuseScore's continuous view answers that with a frozen leading column, and swift-sheet-music ships
/// that column as `StickyHeaderView`. What this container owns is the geometry: when the pane appears, which measure
/// it displays, and where it is drawn so that the handover is invisible.
///
/// **The handover pivots on the bracket.** The pane is hidden until the score's own bracket reaches the viewport's
/// leading edge; at that instant the pane is drawn with ITS bracket at the same viewport X, so every element behind it
/// — bracket, staff name, clef, key, time — is overlapping its counterpart at the moment it appears. Adapted from
/// swift-sheet-music's macOS example container, whose arithmetic this reproduces (see `MacStickyPaneGeometry`).
///
/// **The playback cursor arrives as a value and leaves as an observable write.** `MacScoreContentView` reads the
/// cursors one level below the root; this container takes them as `let`s and forwards them into
/// `MacHorizontalScoreState.cursor`, which only the strip reads. Nothing here and nothing above reads a cursor to
/// render with.
struct MacHorizontalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let showAllMeasureNumbers: Bool
    /// The highlight cursor. Mirrored into `state.cursor`; this view never reads it off the view model.
    let playbackCursor: ScoreCursor?
    /// Lookahead anchor used for the follow trigger ONLY — a cursor a couple of beats ahead of `playbackCursor` during
    /// playback. `nil` when not playing / scrubbing, in which case follow falls back to a keep-in-view.
    let scrollAnchorCursor: ScoreCursor?
    /// User opt-out: when false, continuous playback no longer scrolls the strip.
    let autoFollowEnabled: Bool
    /// Transpose offset in semitones. Only used to invalidate the layout cache via `MacScoreLayoutKey` — the
    /// score passed in is already transposed.
    let transposeSemitones: Int
    /// Which edit `score` is while note editing, 0 otherwise. Keyed on INSTEAD of `editingHost.editGeneration` — see
    /// `ReaderEditingDisplay.version`.
    var editingScoreVersion = 0
    let viewModel: ReaderViewModel
    /// The note-editing seam. `nil` keeps this container byte-identical to the read-only reader (previews, tests).
    /// With a host, clicks route to `editingHost.onTap`, the rebuilt `LayoutDocument` is published to
    /// `editingHost.document` for hit-testing, and the surface tints the selection and draws the caret.
    var editingHost: ReaderEditingHost?

    @State private var state = MacHorizontalScoreState()
    /// Off-main engraver holding this surface's incremental `LayoutCache`; see `ScoreRelayoutEngine`.
    @State private var relayoutEngine = ScoreRelayoutEngine()
    /// Live scroll offset and magnification, mirrored out of AppKit so the sticky pane can track the score it sits
    /// over. See `MacScoreViewportState` — this is the one container that asks for it.
    @State private var viewportState = MacScoreViewportState(tracksScroll: true)
    /// The control channel for magnification: external writes in (the fit seed), the settled value out. The live
    /// value during a pinch is `viewportState.magnification`.
    @State private var magnification: CGFloat = 1.0
    /// Fit-to-window is applied once, when the first engraving lands — a viewer that re-zooms itself while the user
    /// drags the window edge is fighting them. Same decision the page deck made.
    @State private var hasSeededMagnification = false
    /// Bumped on every installed engraving; the only thing that makes the host rebuild the strip.
    @State private var layoutGeneration = 0
    @State private var scrollRequest: MacScoreScrollRequest?
    @State private var scrollToken = 0

    var body: some View {
        GeometryReader { proxy in
            surface(viewport: proxy.size)
        }
    }

    private func surface(viewport: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            MagnifyingScoreScrollView(
                magnification: $magnification,
                contentGeneration: layoutGeneration,
                scrollRequest: scrollRequest,
                viewportState: viewportState,
            ) {
                MacHorizontalScoreStrip(
                    viewModel: viewModel,
                    state: state,
                    document: state.document,
                    score: score,
                    scoreOptions: scoreOptions,
                    viewportState: viewportState,
                    editingHost: editingHost,
                )
            }
            stickyPane
        }
        // A continuous scroll has no desk: the surface IS the paper, white in either appearance, exactly as Vertical
        // mode and the iOS reader draw it. See `MacReaderGround` — this mode adds no ground of its own, and the
        // sticky pane's own white is the same paper carried up over the score.
        //
        // Withheld until the first engraving lands, for the reason the vertical container states: the `ProgressView`
        // underneath is the one thing here that stands on paper and still resolves against the system appearance.
        .background(state.document == nil ? Color.clear : MacReaderGround.paper)
        // The sticky pane is transformed by `scaleEffect`, and SwiftUI does not auto-clip transformed content — its
        // overflow would paint into the sidebar and the transport bar. `contentShape` keeps hit-testing aligned with
        // what is actually visible.
        .clipped()
        .contentShape(Rectangle())
        .task(id: layoutKey) {
            await rebuildLayout()
        }
        // Guarded assignments rather than bare writes: `.onChange(initial: true)` fires during the first render, and
        // an `@Observable` property notifies on every assignment whether or not the value moved. At that moment both
        // of these are already what they would be written, so the guard means the appearing frame performs no
        // observable write at all — which is the difference between one state write in that pass and three.
        .onChange(of: playbackCursor, initial: true) { _, cursor in
            if state.cursor != cursor {
                state.cursor = cursor
            }
        }
        .onChange(of: inkBand(viewport: viewport), initial: true) { _, band in
            if state.inkBand != band {
                state.inkBand = band
            }
        }
        // The stored layer lands from `loadAnnotations()` a beat after the score, so the projection taken at the end
        // of the layout can predate it. Re-projecting here is what makes ink that arrives late appear.
        .onChange(of: viewModel.annotationDrawings) { _, _ in
            projectInk(into: state.document)
        }
        .onChange(of: fitKey(viewport: viewport), initial: true) { _, key in
            seedMagnification(key)
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

    /// The frozen leading column. Everything about it — whether it is on screen, which measure it shows, and where it
    /// is drawn — comes out of `MacStickyPaneGeometry`; `StickyHeaderView` itself is swift-sheet-music's, rendered
    /// from the same engraver that drew the score, so the two agree glyph for glyph.
    @ViewBuilder
    private var stickyPane: some View {
        if let document = state.document, !state.measureContexts.isEmpty {
            let geometry = MacStickyPaneGeometry(document: document, scrollX: viewportState.scroll.x)
            if geometry.isVisible {
                StickyHeaderView(
                    document: document,
                    measureContexts: state.measureContexts,
                    // Driven by the pane's TRAILING edge, not the leftmost visible pixel (which the pane is covering):
                    // the displayed measure flips the moment the next measure's leading barline clears the pane, i.e.
                    // the moment that measure becomes the first thing the reader can actually see.
                    documentScrollX: document.stickyTrailingX(
                        scoreScrollX: geometry.scoreScrollX,
                        measureContexts: state.measureContexts,
                    ),
                )
                // Match the strip's own padding exactly, so the pane's white area starts at the same corner the
                // score's does and the staff lines meet.
                .padding(.leading, MacHorizontalMetrics.contentInset)
                    .padding(.top, MacHorizontalMetrics.contentInset)
                    // Ride the vertical scroll so the pane's staves stay locked to the score's when the reader
                    // has zoomed past the window's height; shift left by the bracket offset so the pane's
                    // bracket lands at the exact viewport X the score's bracket occupies at the visibility
                    // threshold. Both are in unmagnified points and are scaled with the pane, which is why the
                    // scale comes after.
                    .offset(x: -geometry.bracketHostingX, y: -viewportState.scroll.y)
                    .scaleEffect(viewportState.magnification, anchor: .topLeading)
                    // Transparent to the pointer, so it can never swallow a scroll over the leading edge of the
                    // window. The click that then falls through to the music underneath is rejected on the other
                    // side, in `MacHorizontalScoreStrip.tapSeekGesture` — that music is scrolled past, and seeking
                    // to it would move the cursor somewhere the reader cannot see.
                    .allowsHitTesting(false)
            }
        }
    }

    /// Horizontal mode: lay out at natural content width so systems never wrap. The title frame is omitted — it would
    /// push the score down inside what is essentially a single long row. Identical to the iOS container's options,
    /// which is what makes the two modes the same mode.
    private var scoreOptions: ScoreViewOptions {
        MacScoreEngraving.options(
            staffSize: staffSize,
            honorLayoutBreaks: honorLayoutBreaks,
            collapseMultiMeasureRests: collapseMultiMeasureRests,
            showInvisibleElements: showInvisibleElements,
            showAllMeasureNumbers: showAllMeasureNumbers,
            wrapToViewWidth: false,
            includeTitleFrame: false,
        )
    }

    /// No `width`: horizontal mode lays the score out at its natural width, so a resize changes what is visible and
    /// nothing about the engraving.
    private var layoutKey: MacScoreLayoutKey {
        MacScoreLayoutKey(
            score: score,
            size: staffSize,
            honorLayoutBreaks: honorLayoutBreaks,
            collapseMultiMeasureRests: collapseMultiMeasureRests,
            showInvisibleElements: showInvisibleElements,
            showAllMeasureNumbers: showAllMeasureNumbers,
            transposeSemitones: transposeSemitones,
            editingScoreVersion: editingScoreVersion,
        )
    }

    /// Engrave at the score's own uncompressed width, then build the sticky pane's per-measure state from the same
    /// score. Neither depends on the window, so a resize changes the magnification and nothing about the engraving.
    private func rebuildLayout() async {
        let newDocument = await relayoutEngine.layoutAtNaturalWidth(score: score, options: scoreOptions)
        guard !Task.isCancelled else { return }
        let contexts = LayoutEngine.measureContexts(for: score)
        state.measureContexts = contexts
        state.document = newDocument
        editingHost?.document = newDocument
        projectInk(into: newDocument)
        layoutGeneration += 1
    }

    /// Place the stored ink in `document`'s coordinate space. Called from the relayout task and from the
    /// annotation-layer watcher — never from a body, and in particular never from the strip, whose body re-runs on
    /// every playback tick. Same rule `MacInkProjection` states for the vertical container.
    private func projectInk(into document: LayoutDocument?) {
        state.ink = MacScoreEngraving.projectedInk(viewModel, into: document)
    }

    /// The column of document space the window currently shows, snapped to the ink raster's grid.
    private func inkBand(viewport: CGSize) -> CGRect {
        guard let document = state.document else { return .zero }
        let magnification = max(viewportState.magnification, 0.01)
        return MacScoreInkOverlay.horizontalScrollBand(
            left: viewportState.scroll.x - MacHorizontalMetrics.contentInset,
            width: viewport.width / magnification,
            in: document.size,
        )
    }

    private func fitKey(viewport: CGSize) -> MacHorizontalFitKey {
        MacHorizontalFitKey(viewport: viewport, documentSize: state.document?.size)
    }

    private func seedMagnification(_ key: MacHorizontalFitKey) {
        guard !hasSeededMagnification, let documentSize = key.documentSize,
              key.viewport.width > 0, key.viewport.height > 0
        else { return }
        hasSeededMagnification = true
        magnification = MacHorizontalMetrics.fitMagnification(documentSize: documentSize, viewport: key.viewport)
    }

    /// Playback follow, in the hosted content's own unmagnified coordinates — which is the space
    /// `MacScoreScrollRequest.origin` is expressed in, and the space `viewportState.scroll` is reported in, so the
    /// arithmetic never has to cross the magnification.
    ///
    /// Identical policy to the iOS horizontal container, out of the same `Domain` implementations: during playback the
    /// playing measure is pinned near the leading edge and only re-scrolled once it (or the lookahead a couple of
    /// beats ahead) leaves the window; paused / scrubbing falls back to a gentle keep-in-view. The vertical axis is
    /// always keep-in-view — there is nothing to pin to when the whole score is one system tall.
    private func autoScroll(viewport: CGSize) {
        guard let cursor = playbackCursor, let document = state.document else { return }
        let magnification = max(viewportState.magnification, 0.01)
        let inset = MacHorizontalMetrics.contentInset
        // The window measured in the content's own units: the follow math compares positions against a viewport, and
        // those positions are unmagnified.
        let windowWidth = viewport.width / magnification
        let windowHeight = viewport.height / magnification
        let pad = 8 * document.metrics.sp
        let currentX = viewportState.scroll.x
        let currentY = viewportState.scroll.y

        let targetX: CGFloat = if let lookahead = scrollAnchorCursor,
                                  let playing = measureRect(for: cursor, in: document),
                                  let ahead = measureRect(for: lookahead, in: document)
        {
            // Axis-agnostic reuse of `scrollOffsetPinningSystemTop`, exactly as the iOS container does it: the
            // "system" parameters carry the playing measure's X span and `topInset` is the leading pad.
            CGFloat(scrollOffsetPinningSystemTop(
                current: Double(currentX),
                systemMin: Double(playing.minX + inset),
                systemMax: Double(playing.maxX + inset),
                lookaheadMax: Double(ahead.maxX + inset),
                viewport: Double(windowWidth),
                topInset: Double(pad),
            ))
        } else if let playing = measureRect(for: cursor, in: document) {
            CGFloat(horizontalMeasureScrollOffset(
                current: Double(currentX),
                measureMin: Double(playing.minX + inset),
                measureMax: Double(playing.maxX + inset),
                viewport: Double(windowWidth),
                pad: Double(pad),
            ))
        } else {
            currentX
        }

        let targetY: CGFloat = if let frame = document.cursorFrame(for: cursor, in: score) {
            CGFloat(scrollOffsetKeepingInView(
                current: Double(currentY),
                targetMin: Double(frame.minY + inset),
                targetMax: Double(frame.maxY + inset),
                viewport: Double(windowHeight),
                pad: Double(pad),
            ))
        } else {
            currentY
        }

        // Clamped here rather than left to AppKit: `setBoundsOrigin` is not constrained the way a user scroll is, so
        // an offset past the end would leave the strip parked in blank space.
        let content = CGSize(
            width: document.size.width + inset * 2,
            height: document.size.height + inset * 2,
        )
        let clamped = CGPoint(
            x: min(max(0, targetX), max(0, content.width - windowWidth)),
            y: min(max(0, targetY), max(0, content.height - windowHeight)),
        )
        guard abs(clamped.x - currentX) >= 0.5 || abs(clamped.y - currentY) >= 0.5 else { return }
        scrollToken += 1
        scrollRequest = MacScoreScrollRequest(token: scrollToken, target: .origin(clamped))
    }

    /// Content rect of the measure the cursor sits on, regardless of `.item` vs `.beat`. The follow trigger is "the
    /// measure overflows the window", not "the cursor crosses an edge" — the same rule the iOS container applies.
    ///
    /// **The scan over every system is defensive, not load-bearing: this mode engraves to exactly one.** It was
    /// written believing an honored layout break could put measures on a second row, and that turns out to be
    /// impossible while `wrapToViewWidth` is false — see `MacStickyPaneGeometry.bracketHostingX` for the measurement
    /// and the engraver gate that settles it. The loop is kept because it costs one comparison on a one-element
    /// array and is the shape that stays correct if that ever changes.
    private func measureRect(for cursor: ScoreCursor, in document: LayoutDocument) -> CGRect? {
        let index = measureIndex(of: cursor)
        for system in document.systems {
            if let measure = system.measures.first(where: { $0.measureIndex == index }) {
                return CGRect(
                    x: system.origin.x + measure.origin.x,
                    y: system.origin.y + measure.origin.y,
                    width: measure.width,
                    height: system.size.height,
                )
            }
        }
        return nil
    }
}
#endif
