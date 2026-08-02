// swiftlint:disable file_length
// HorizontalScoreContainer hosts the natural-width scroll / pinch / zoom pipeline plus the annotation overlay and
// auto-scroll plumbing for the horizontal Reader; its breadth keeps it just over the file_length budget.

import Domain
import PencilKit
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Lays the score out at its natural width — no system wrapping — inside a `ScoreScrollHost`. The user scrolls one long
/// row of measures; pinch / double-tap zoom follow the same composition as `VerticalScoreContainer`. See that file's
/// docblock for the pinch / scaleEffect rationale; axes are swapped here (X is the always-scrollable axis).
struct HorizontalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let playbackCursor: ScoreCursor?
    /// Lookahead anchor (2 beats ahead) used for the X auto-scroll trigger ONLY — never the highlight. `nil`
    /// when not playing, in which case the scroll falls back to the reactive measure keep-in-view.
    let scrollAnchorCursor: ScoreCursor?
    /// User opt-out: when false, continuous playback no longer auto-scrolls. Manual navigation still keeps its
    /// target in view (see `readerShouldFollowPlayback`).
    let autoFollowEnabled: Bool
    /// Transpose offset in semitones. Only used to invalidate the layout cache via `TaskKey` — the score passed in is
    /// already transposed. Without this the `TaskKey.scoreSignature` hash doesn't change on transpose and the layout
    /// task never re-runs.
    let transposeSemitones: Int
    /// Which edit `score` is while note editing, 0 otherwise. Keyed on INSTEAD of `editingHost.editGeneration`:
    /// read from the host here, the key advanced before the new score arrived. See `ReaderRootScreen`.
    let editingScoreVersion: Int
    @Bindable var viewModel: ReaderViewModel
    /// Note-editing seam, mirroring `VerticalScoreContainer`: while editing, taps select instead of seeking, the
    /// rebuilt document is published to the host, and `editGeneration` joins the layout task's identity so an edit
    /// that doesn't change the score's hash still relays out.
    var editingHost: ReaderEditingHost?

    /// Layout output — observable, not `@State`; see `ScoreLayoutState` for why.
    @State private var layoutState = ScoreLayoutState()
    /// Off-main engraver holding this surface's incremental `LayoutCache`; see `ScoreRelayoutEngine`.
    @State private var relayoutEngine = ScoreRelayoutEngine()

    private var document: LayoutDocument? {
        get { layoutState.document }
        nonmutating set { layoutState.document = newValue }
    }

    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var contentInsetTop: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    @State private var pinch = PinchState()
    /// Mirror of `viewModel.viewportZoom` set OUTSIDE any `withAnimation` block so it reflects the final committed
    /// value immediately — the `expectedContentSize` closure reads this to dodge SwiftUI's animated interpolation while
    /// the commit transition is in flight.
    @State private var committedZoom: CGFloat = 1.0
    /// The annotation model projected to the current layout. Recomputed on reflow / score-swap and appear — NOT on
    /// scroll/pinch — so per-tick rendering stays cheap. Passed to the canvas as the seed drawing. Mirrors
    /// `VerticalScoreContainer.projectedAnnotations`.
    @State private var projectedAnnotations = PKDrawing()
    /// Stable handle the canvas controller links itself into (see `AnnotationCanvasHandle`). Continuous-scroll mode
    /// has no page-turn commit, so nothing calls `reseedForPageTurn` here — the handle only satisfies the shared
    /// `AnnotationOverlaySpec` initializer.
    @State private var annotationHandle = AnnotationCanvasHandle()

    private let scorePadding: CGFloat = 16

    private struct PinchSession {
        var baseZoom: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            scrollContent(viewport: proxy.size)
                .onAppear { eagerLayoutIfNeeded() }
                .task(id: TaskKey(
                    score: score, size: staffSize,
                    honorLayoutBreaks: honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    showInvisibleElements: showInvisibleElements,
                    transposeSemitones: transposeSemitones,
                    editGeneration: editingScoreVersion,
                )) {
                    await rebuildLayout()
                }
        }
    }

    // swiftlint:disable:next function_body_length
    private func scrollContent(viewport: CGSize) -> some View {
        // Observe live magnification so each frame of a commit-reset ease re-renders this view → the host re-syncs the
        // annotation canvas, keeping the ink locked to the score through the eased zoom commit (see PinchState).
        _ = pinch.magnification
        return ScoreScrollHost(
            contentOffset: $liveScrollOffset,
            contentInsetTop: $contentInsetTop,
            pendingScroll: $pendingScroll,
            alwaysBounceVertical: false,
            alwaysBounceHorizontal: true,
            centerVertically: true,
            centerHorizontally: false,
            expectedContentSize: {
                let doc = document?.size ?? .zero
                let zoom = committedZoom
                return CGSize(
                    width: (doc.width + scorePadding * 2) * zoom,
                    height: (doc.height + scorePadding * 2) * zoom,
                )
            },
            onPinchBegan: { anchor, _ in
                pinch.cancelResetAnimation() // don't let a trailing commit ease fight the new gesture
                pinchSession = PinchSession(baseZoom: viewModel.viewportZoom)
                pinch.anchor = anchor
                pinch.magnification = 1.0
                pinch.offsetY = 0
            },
            onPinchChanged: { magnification, translation in
                // X is fed back through `UIScrollView.contentOffset` natively (horizontal extent always exists in this
                // mode); only Y needs a live offset.
                pinch.magnification = magnification
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
            onUserViewportInteractionBegan: {
                viewModel.playbackSession.suspendPlaybackFollowForManualViewportChange()
            },
            annotationOverlay: annotationSpec(viewport: viewport),
        ) {
            HorizontalZoomedSurface(
                viewModel: viewModel,
                pinch: pinch,
                document: document,
                score: score,
                viewport: viewport,
                scorePadding: scorePadding,
                scoreOptions: scoreOptions,
                playbackCursor: playbackCursor,
                lastManualCursor: $lastManualCursor,
                editingHost: editingHost,
            )
        }
        // Let the score reach the screen edges and slide under the translucent overlays — the `UIViewRepresentable`'s
        // UIView frame is otherwise shrunk by the system safe area and parent overlay reserve.
        .ignoresSafeArea()
        .onChange(of: [playbackCursor, scrollAnchorCursor]) { old, new in
            guard readerShouldFollowPlayback(
                autoFollowEnabled: autoFollowEnabled,
                isPlaybackDriven: scrollAnchorCursor != nil,
                cursorMoved: old[0] != new[0],
                followSuspended: viewModel.playbackSession.isPlaybackFollowSuspended,
            ) else { return }
            autoScroll(realCursor: playbackCursor, lookaheadCursor: scrollAnchorCursor, viewport: viewport)
        }
        // Reproject on reflow / score-swap / appear and on async annotation-load (not while annotating).
        .onChange(of: document) { _, _ in reprojectAnnotations() }
        .onAppear { reprojectAnnotations() }
        .onChange(of: viewModel.annotationDrawings) { _, _ in
            if !viewModel.isAnnotating { reprojectAnnotations() }
        }
    }

    /// Folds a finished pinch into `viewportZoom` and queues a scroll so the content under the user's fingers at
    /// release lands on the same screen position post-commit. Horizontal pan-during-pinch rides on `currentOffset`
    /// (UIScrollView native); vertical rides on `pinch.offsetY`. See `VerticalScoreContainer.commitPinch` for the full
    /// rationale on the two-phase snap-to-unit and the scale-state-snap to avoid mid-animation bulge.
    private func commitPinch(
        magnification: CGFloat,
        startLocation: CGPoint,
        currentOffset: CGPoint,
        viewport: CGSize,
    ) {
        let session = pinchSession ?? PinchSession(baseZoom: viewModel.viewportZoom)
        pinchSession = nil

        let r = ReaderPinchCommit.resolve(PinchCommitInput(
            baseZoom: session.baseZoom, magnification: magnification,
            startLocation: startLocation, currentOffset: currentOffset,
            offsetX: 0, offsetY: pinch.offsetY,
        ))
        // Pre-compute the post-commit contentInset.top so we can clamp `scrollToTarget.y` against the actual valid
        // contentOffset range — UIScrollView would otherwise re-clamp on the next layout pass, visible as a one-frame
        // upward jump.
        let docHeight = document?.size.height ?? 0
        let postFramedH = (docHeight + scorePadding * 2) * r.targetZoom
        let postInsetTop = max(0, (viewport.height - postFramedH) / 2)
        let scrollToTarget = CGPoint(x: max(0, r.rawScrollTarget.x), y: max(-postInsetTop, r.rawScrollTarget.y))

        if r.isBounceBack {
            // Ease frame-by-frame (CADisplayLink) so the annotation ink overlay follows the rubber-band release in
            // lockstep instead of snapping ahead — see PinchState. (Was `withAnimation`, which the ink couldn't track.)
            pinch.animateReset(toMagnification: 1.0, offsetX: 0, offsetY: 0)
        } else {
            committedZoom = r.targetZoom
            pendingScroll = .immediate(scrollToTarget)
            if r.snapToUnit {
                viewModel.resetZoom()
                pinch.magnification = r.compensatedMag
                pinch.animateReset(toMagnification: 1.0, offsetX: 0, offsetY: 0)
            } else {
                viewModel.viewportZoom = r.targetZoom
                pinch.magnification = 1.0
                pinch.anchor = .center

                let scrollAbsorbsOffset = postFramedH > viewport.height
                if pinch.offsetY != 0, !scrollAbsorbsOffset {
                    pinch.animateReset(toMagnification: pinch.magnification, offsetX: 0, offsetY: 0)
                } else {
                    pinch.offsetY = 0
                }
            }
        }
    }

    private func annotationSpec(viewport: CGSize) -> AnnotationOverlaySpec {
        AnnotationOverlaySpec(
            isAnnotating: viewModel.isAnnotating,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            displayDrawing: projectedAnnotations,
            onChange: { drawing in
                guard let doc = document else { return }
                // Canvas is the source of truth while drawing: keep the projection equal to the live ink so the next
                // render's `applyDrawing` is a no-op (echo guard). The model is still captured for persistence/reflow.
                projectedAnnotations = drawing
                viewModel.annotationDrawingsDidChange(AnnotationAnchoring.capture(strokes: drawing.strokes, in: doc))
            },
            state: { annotationCanvasState(viewport: viewport) },
            handle: annotationHandle,
        )
    }

    /// Geometry the canvas mirrors onto PencilKit's scroll machinery. Same composition as
    /// `VerticalScoreContainer.annotationCanvasState`, adapted for Horizontal: committed zoom = `viewportZoom` (no
    /// fit-to-width), symmetric `scorePadding`, X scrolled natively (no `pinch.offsetX`), Y carried by `pinch.offsetY`.
    /// Vertical centering rides on the host's real `contentOffset` (added by the controller), so it cancels here.
    private func annotationCanvasState(viewport _: CGSize) -> AnnotationCanvasState {
        guard let doc = document else {
            return .init(documentSize: .zero, zoomScale: 1, contentOffsetBias: .zero, contentInset: .zero)
        }
        let zoomC = viewModel.viewportZoom // committed zoom, no live magnification, no fit-to-width
        let m = pinch.magnification
        let z = zoomC * m
        let pad = scorePadding
        let anchorTermX = pinch.anchor.x * (doc.size.width + pad * 2) * (1 - m) * zoomC
        let anchorTermY = pinch.anchor.y * (doc.size.height + pad * 2) * (1 - m) * zoomC
        return AnnotationCanvasState(
            documentSize: doc.size,
            zoomScale: z,
            contentOffsetBias: CGPoint(
                x: -pad * z - anchorTermX,
                y: -pad * z - anchorTermY - pinch.offsetY,
            ),
            contentInset: UIEdgeInsets(top: 100_000, left: 100_000, bottom: 100_000, right: 100_000),
        )
    }

    private func reprojectAnnotations() {
        guard let doc = document else { projectedAnnotations = PKDrawing(); return }
        projectedAnnotations = AnnotationAnchoring.display(viewModel.annotationDrawings, in: doc)
    }

    /// Horizontal mode: lay out at natural content width so systems never wrap. Title frame is omitted — it'd push the
    /// score down inside what is essentially a single long row.
    private var scoreOptions: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: false, includeTitleFrame: false,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            breakIndicatorVisibility: .none,
            multiMeasureRest: collapseMultiMeasureRests
                ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
                : .disabled,
            showsInvisibleElements: showInvisibleElements,
        )
    }

    /// SwiftUI `#Preview` snapshots the view tree before the async `.task` (which hops to a detached background
    /// `LayoutEngine.layout`) completes, so `document` is still nil and the score area renders blank. When running
    /// under Xcode Previews, lay the score out synchronously on first appearance so the snapshot has a populated
    /// `document`. No-op in the real app / live capture (those let the async path run and never enter this branch).
    private func eagerLayoutIfNeeded() {
        guard document == nil else { return }
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" else { return }
        let natural = LayoutEngine.naturalContentWidth(score: score, options: scoreOptions)
        document = LayoutEngine.layout(score: score, options: scoreOptions, availableWidth: natural)
    }

    private func rebuildLayout() async {
        // Off-main on `relayoutEngine`'s executor, reusing the previous engrave's `LayoutCache` — see
        // `ScoreRelayoutEngine` and `VerticalScoreContainer.rebuildLayout`.
        let newDoc = await relayoutEngine.layoutAtNaturalWidth(score: score, options: scoreOptions)
        guard !Task.isCancelled else { return }
        document = newDoc
        editingHost?.document = newDoc
    }

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

        // Cursor frame in scroll-content coords: padded then scaled from top-leading. Mirrors
        // `HorizontalZoomedSurface`'s composition. Only Y rides on the cursor frame; X anchors on the whole measure.
        let minY = (rect.minY + scorePadding) * zoom
        let maxY = (rect.maxY + scorePadding) * zoom

        let curX = liveScrollOffset.x
        let curY = liveScrollOffset.y

        let newX: CGFloat = if let lookaheadCursor,
                               let realMeasure = measureRect(for: realCursor, in: doc),
                               let lookMeasure = measureRect(for: lookaheadCursor, in: doc)
        {
            // Playback: left-align the playing cursor's MEASURE, re-scrolling only when that measure or the
            // lookahead measure leaves the viewport. Axis-agnostic reuse of `scrollOffsetPinningSystemTop`:
            // the "system" params carry the playing measure's X-span; `lookaheadMax` is the lookahead
            // measure's right edge; `topInset` is the leading pad.
            CGFloat(scrollOffsetPinningSystemTop(
                current: Double(curX),
                systemMin: Double((realMeasure.minX + scorePadding) * zoom),
                systemMax: Double((realMeasure.maxX + scorePadding) * zoom),
                lookaheadMax: Double((lookMeasure.maxX + scorePadding) * zoom),
                viewport: Double(viewport.width),
                topInset: Double(pad),
            ))
        } else if let measure = measureRect(for: realCursor, in: doc) {
            // Paused / scrubbing / manual seek: reactive measure keep-in-view (today's behavior).
            CGFloat(horizontalMeasureScrollOffset(
                current: Double(curX),
                measureMin: Double((measure.minX + scorePadding) * zoom),
                measureMax: Double((measure.maxX + scorePadding) * zoom),
                viewport: Double(viewport.width),
                pad: Double(pad),
            ))
        } else {
            curX
        }
        let newY = adjustedScrollOffset(
            currentOffset: curY,
            targetMin: minY, targetMax: maxY,
            viewportSize: viewport.height, pad: pad,
        )

        if abs(newX - curX) < 0.5, abs(newY - curY) < 0.5 { return }

        pendingScroll = .animated(CGPoint(x: newX, y: newY))
    }

    /// Scroll-content rect of the measure the cursor sits on, regardless of `.item` vs `.beat`. The auto-scroll trigger
    /// is "the measure overflows the viewport", not "the cursor itself crosses an edge" — mirrors
    /// `ScorePiPFrameRenderer.measureDocRect`. Scans every system so honored layout breaks (multi-row layouts) resolve.
    private func measureRect(for cursor: ScoreCursor, in doc: LayoutDocument) -> CGRect? {
        for system in doc.systems {
            if let measure = system.measures.first(where: { $0.measureIndex == cursor.measureIndex }) {
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

    /// Smallest scroll offset that keeps `[targetMin, targetMax]` inside the viewport with `pad` margin. Same shape as
    /// `VerticalScoreContainer.adjustedScrollOffset`.
    private func adjustedScrollOffset(
        currentOffset cur: CGFloat,
        targetMin: CGFloat,
        targetMax: CGFloat,
        viewportSize: CGFloat,
        pad: CGFloat,
    ) -> CGFloat {
        let viewMin = cur
        let viewMax = cur + viewportSize
        if targetMax - targetMin > viewportSize {
            return max(0, targetMin)
        }
        if targetMin >= viewMin, targetMax <= viewMax {
            return cur
        }
        if targetMin < viewMin {
            return max(0, targetMin - pad)
        }
        return targetMax - viewportSize + pad
    }

    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let honorLayoutBreaks: Bool
        let collapseMultiMeasureRests: Bool
        let showInvisibleElements: Bool
        let transposeSemitones: Int
        let editGeneration: Int

        init(
            score: Score,
            size: CGFloat,
            honorLayoutBreaks: Bool,
            collapseMultiMeasureRests: Bool,
            showInvisibleElements: Bool,
            transposeSemitones: Int,
            editGeneration: Int,
        ) {
            self.editGeneration = editGeneration
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
                ^ score.openingClefSignature
                ^ (transposeSemitones << 24)
            self.size = size
            self.honorLayoutBreaks = honorLayoutBreaks
            self.collapseMultiMeasureRests = collapseMultiMeasureRests
            self.showInvisibleElements = showInvisibleElements
            self.transposeSemitones = transposeSemitones
        }
    }
}
