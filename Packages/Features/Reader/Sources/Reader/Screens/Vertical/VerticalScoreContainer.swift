// swiftlint:disable file_length
// VerticalScoreContainer hosts the UIKit-backed scroll / pinch / zoom pipeline plus the layout, fit-to-width, and
// auto-scroll plumbing for the vertical Reader; its breadth keeps it just over the file_length budget.

import Domain
import PencilKit
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Wraps `ScoreView(document:score:)` in a `ScoreScrollHost` (UIKit-backed) and recomputes the `LayoutDocument`
/// whenever the score, staff size, or container width changes.
///
/// Drives playback auto-scroll: during playback it pins the playing cursor's system to the top of the viewport,
/// re-scrolling only when that system or the lookahead cursor (`scrollAnchorCursor`, a couple beats ahead) leaves
/// the viewport — so the cursor drifts down between scrolls. When paused / scrubbing it falls back to a gentle
/// keep-in-view. Horizontal follow only kicks in once `viewportZoom` makes the content wider than the viewport.
///
/// Owns pinch zoom. The score content is `scaleEffect`-ed *inside* the scroll host (with an explicit scaled `.frame`)
/// so the underlying `UIScrollView` is never zoomed — `maximumZoomScale` is pinned at 1 and it scrolls the zoomed
/// extent natively. That keeps the SwiftUI `Canvas` re-rasterising under `scaleEffect` (sharp throughout) instead of
/// falling back to a `CALayer` bitmap upscale.
///
/// During a live pinch, two `scaleEffect`s compose: inner `pinch.magnification` with `anchor: pinch.anchor` pivots the
/// visual around the user's fingers; outer committed `viewportZoom` with `anchor: .topLeading` drives the `.frame`
/// size and scrollable extent. On gesture end the live factor is folded into `viewportZoom` and a scroll command is
/// queued so the pinch's content point stays under the same viewport coord.
struct VerticalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let showAllMeasureNumbers: Bool
    let playbackCursor: ScoreCursor?
    /// Lookahead anchor used for auto-scroll ONLY — a cursor a couple of beats ahead of `playbackCursor` during
    /// playback, so the viewport scrolls before the playing cursor reaches the edge. `nil` when not playing /
    /// scrubbing, in which case auto-scroll falls back to `playbackCursor`. Never passed to the highlight.
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
    /// Content height the bottom transport control reserves above the bottom safe area (collapsed pill or expanded seek
    /// card). The scroll content pads its bottom by this plus the bottom safe-area inset — i.e. the full distance from
    /// the control's top edge to the screen's bottom edge — so the last system clears the control when scrolled fully
    /// down. The control floats over this padding in a sibling overlay; vertical mode reserves no `safeAreaPadding`.
    let bottomControlClearance: CGFloat
    @Bindable var viewModel: ReaderViewModel
    /// Drives the note-editing overlay: `nil` (or `isEditing == false`) keeps every editing seam byte-identical to
    /// the non-editing path. While editing, taps route to `editingHost.onTap` instead of the manual-cursor seek, the
    /// rebuilt `LayoutDocument` is published to `editingHost.document` for the App-side editing chrome, and
    /// `editingHost.editGeneration` is folded into the layout task's identity so an edit that doesn't change the
    /// score's structural signature (e.g. a pitch-drag on an existing note) still triggers a relayout.
    var editingHost: ReaderEditingHost?

    /// Layout output — observable, not `@State`; see `ScoreLayoutState` for why.
    @State private var layoutState = ScoreLayoutState()
    /// Off-main engraver holding this surface's incremental `LayoutCache`; see `ScoreRelayoutEngine`.
    @State private var relayoutEngine = ScoreRelayoutEngine()

    private var document: LayoutDocument? {
        get { layoutState.document }
        nonmutating set { layoutState.document = newValue }
    }

    @State private var lastWidth: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: VerticalPinchSession?
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var contentInsetTop: CGFloat = 0
    /// Total top chrome inset: the system safe area plus the Reader's self-drawn top bar (`ReaderTopBar`). The
    /// continuous scroll slides underneath both, so the scroll content pads its top by exactly this much to put the
    /// first system clear of them. Measured rather than assumed — the bar's height varies with orientation and device.
    @State private var topChromeInset: CGFloat = 0
    /// System bottom safe-area inset (home-indicator region). Added to `bottomControlClearance` so the scroll content's
    /// bottom padding spans from the transport control's top edge all the way to the physical screen bottom.
    @State private var safeAreaBottom: CGFloat = 0
    /// Live pinch state held as `@Observable` so mutations propagate into the hosted score subtree via observation —
    /// not through `rootView` reassignment, which drops the `withAnimation { … }` transaction. See `PinchState`.
    @State private var pinch = PinchState()
    /// Mirror of `viewModel.viewportZoom` set OUTSIDE `withAnimation` so the `expectedContentSize` closure reads the
    /// final committed value instead of SwiftUI's interpolated values during a commit transition.
    @State private var committedZoom: CGFloat = 1.0
    /// The annotation model projected to the current layout. Recomputed only when `document` or the model changes —
    /// NOT on scroll/pinch — so per-tick rendering stays cheap. Passed to the canvas as the seed drawing.
    @State private var projectedAnnotations = PKDrawing()
    /// Stable handle the canvas controller links itself into (see `AnnotationCanvasHandle`). Continuous-scroll mode
    /// has no page-turn commit, so nothing calls `reseedForPageTurn` here — the handle only satisfies the shared
    /// `AnnotationOverlaySpec` initializer.
    @State private var annotationHandle = AnnotationCanvasHandle()

    /// Vertical padding inside the scaled content, on top of `topChromeInset` — which already covers the nav chrome /
    /// safe area the score slides underneath thanks to `ignoresSafeArea()`. Only the editing cluster adds to it.
    private var scoreTopPadding: CGFloat {
        editingChromeInsets.top
    }

    /// Bottom padding inside the scaled content: the full clearance from the transport control's top edge to the
    /// physical screen bottom (control content height + bottom safe area). Lets the last system scroll out from under
    /// the floating control so the whole score is visible at the bottom of the scroll.
    private var scoreBottomPadding: CGFloat {
        bottomControlClearance + safeAreaBottom + editingChromeInsets.bottom
    }

    /// Room the editing cluster occupies, added to the scroll content's padding so the first / last system can still
    /// be brought clear of it. This is PADDING INSIDE THE SCROLL CONTENT — the engine's `availableWidth` is
    /// untouched, so docking or moving the pad never re-engraves the score.
    private var editingChromeInsets: (top: CGFloat, bottom: CGFloat) {
        guard let host = editingHost, host.isEditing else { return (0, 0) }
        return (host.editingChromeTopInset, host.editingChromeBottomInset)
    }

    /// Horizontal inset applied to the score on iPad (0 on iPhone) so Vertical mode matches Page mode's score width
    /// and keeps comfortable margins off the bezel. See `ReaderScoreLayout`.
    private func scoreInset(viewportWidth: CGFloat) -> CGFloat {
        ReaderScoreLayout.scoreHorizontalInset(viewportWidth: viewportWidth, phoneDefault: 0)
    }

    var body: some View {
        GeometryReader { proxy in
            // Any horizontal overflow in `doc.size.width` (engine right margin, spanners, ties) is absorbed by
            // `effectiveZoom`'s fit-to-width factor so the user always sees the entire system at user-zoom 1.0.
            // iPad insets the score by a horizontal margin (matching Page mode); the score lays out at the inset width
            // and the surface re-applies the same margin so it sits centered with bezel clearance.
            let layoutWidth = max(
                proxy.size.width - scoreInset(viewportWidth: proxy.size.width) * 2,
                staffSize * 4,
            )
            scrollContent(viewport: proxy.size)
                .onAppear { eagerLayoutIfNeeded(width: layoutWidth) }
                .onChange(of: layoutWidth) { _, newWidth in eagerLayoutIfNeeded(width: newWidth) }
                .task(id: TaskKey(
                    score: score, size: staffSize, width: layoutWidth,
                    honorLayoutBreaks: honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    showInvisibleElements: showInvisibleElements,
                    showAllMeasureNumbers: showAllMeasureNumbers,
                    transposeSemitones: transposeSemitones,
                    editGeneration: editingScoreVersion,
                )) {
                    await rebuildLayout(width: layoutWidth)
                }
        }
        .background {
            // Sibling reader extending beyond safe area (the main GR sits inside it and reports zero), so its reported
            // top inset is the whole chrome the scroll slides under: status bar plus the self-drawn top bar.
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    max(0, proxy.safeAreaInsets.top)
                } action: { newValue in
                    topChromeInset = newValue
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    max(0, proxy.safeAreaInsets.bottom)
                } action: { newValue in
                    safeAreaBottom = newValue
                }
        }
    }

    private func scrollContent(viewport: CGSize) -> some View {
        VerticalReaderShell(
            viewModel: viewModel,
            pinch: pinch,
            viewport: viewport,
            liveScrollOffset: $liveScrollOffset,
            contentInsetTop: $contentInsetTop,
            pendingScroll: $pendingScroll,
            committedZoom: $committedZoom,
            pinchSession: $pinchSession,
            expectedContentSize: {
                guard let doc = document else { return .zero }
                // Fit the *padded* content (score + horizontal inset) into the viewport so the inset score lands
                // centered with bezel margins, mirroring `VerticalZoomedSurface`'s framed width.
                let framedContentWidth = doc.size.width + scoreInset(viewportWidth: viewport.width) * 2
                let fit = framedContentWidth > 0
                    ? min(1.0, viewport.width / framedContentWidth)
                    : 1.0
                let zoom = committedZoom * fit
                let topPad = scoreTopPadding + topChromeInset
                return CGSize(
                    width: framedContentWidth * zoom,
                    height: (doc.size.height + topPad + scoreBottomPadding) * zoom,
                )
            },
            annotationOverlay: annotationSpec(viewport: viewport),
            onPinchCommitDocWidth: { document?.size.width ?? 0 },
            onUserViewportInteractionBegan: {
                viewModel.playbackSession.suspendPlaybackFollowForManualViewportChange()
            },
        ) {
            VerticalZoomedSurface(
                viewModel: viewModel,
                pinch: pinch,
                document: document,
                score: score,
                viewport: viewport,
                horizontalPadding: scoreInset(viewportWidth: viewport.width),
                scoreTopPadding: scoreTopPadding,
                scoreBottomPadding: scoreBottomPadding,
                topChromeInset: topChromeInset,
                scoreOptions: scoreOptions,
                playbackCursor: playbackCursor,
                lastManualCursor: $lastManualCursor,
                editingHost: editingHost,
            )
        }
        .onChange(of: [playbackCursor, scrollAnchorCursor]) { old, new in
            guard readerShouldFollowPlayback(
                autoFollowEnabled: autoFollowEnabled,
                isPlaybackDriven: scrollAnchorCursor != nil,
                cursorMoved: old[0] != new[0],
                followSuspended: viewModel.playbackSession.isPlaybackFollowSuspended,
            ) else { return }
            autoScroll(realCursor: playbackCursor, lookaheadCursor: scrollAnchorCursor, viewport: viewport)
        }
        // Reproject (and reseed the canvas) ONLY on reflow / score-swap (document changes) and initial appear — NOT on
        // `viewModel.annotationDrawings`. While the user is drawing, the canvas is the source of truth; reseeding it
        // with the round-tripped `display(...)` projection (different bytes from the live ink, so the echo guard can't
        // suppress it) would wipe the just-committed stroke. The user-edit path instead keeps `projectedAnnotations`
        // equal to the live drawing (see `annotationSpec`), so `applyDrawing` is a no-op for the user's own ink.
        .onChange(of: document) { _, _ in reprojectAnnotations() }
        // The one time the MODEL moves under the canvas rather than the other way round: a part add / remove /
        // reorder rewrites every stroke's anchor, so what is on screen is now drawn against the wrong staves. See
        // `ReaderViewModel.annotationReseedTicket`.
        .onChange(of: viewModel.annotationReseedTicket) { _, _ in reprojectAnnotations() }
        .onAppear { reprojectAnnotations() }
    }

    /// Geometry the annotation canvas mirrors onto PencilKit's own scroll machinery (read at call time by the host's
    /// sync, so the ink tracks the score during scroll/pinch). The canvas view is viewport-sized; PencilKit holds the
    /// tall document in its own contentSize/zoomScale/contentOffset — which keeps the live-stroke render surface under
    /// the Metal texture limit (the fix for the draw-time enlarge).
    /// Opt-in annotation overlay config for the host. The `state` closure recomputes the canvas mirror geometry at
    /// call time (read by the host's scroll/pinch sync), so it tracks without a SwiftUI render round-trip.
    private func annotationSpec(viewport: CGSize) -> AnnotationOverlaySpec {
        AnnotationOverlaySpec(
            isAnnotating: viewModel.isAnnotating,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            displayDrawing: projectedAnnotations,
            onChange: { drawing in
                guard let doc = document else { return }
                // The canvas is the source of truth while the user draws: keep the displayed projection EQUAL to the
                // live ink so the next render's `applyDrawing` is a no-op (the echo guard sees no change) and never
                // round-trips/wipes the just-committed stroke. The model is still captured for persistence + reflow;
                // reflow/load reproject from the model via `reprojectAnnotations()` (on `document` change / appear).
                projectedAnnotations = drawing
                // Only the score layer is re-captured. An item read out of a PDF also carries page-anchored ink, which
                // this canvas can neither show nor describe — committing the capture verbatim would delete it, and the
                // save coordinator would make that permanent.
                viewModel.annotationDrawingsDidChange(AnnotationLayers.replacing(
                    .score,
                    in: viewModel.annotationDrawings,
                    with: AnnotationAnchoring.capture(strokes: drawing.strokes, in: doc),
                ))
            },
            state: { annotationCanvasState(viewport: viewport) },
            handle: annotationHandle,
            isInkDimmed: editingHost?.isEditing == true,
        )
    }

    private func annotationCanvasState(viewport: CGSize) -> AnnotationCanvasState {
        guard let doc = document else {
            return AnnotationCanvasState(
                documentSize: .zero, zoomScale: 1, contentOffsetBias: .zero, contentInset: .zero,
            )
        }
        let zoomC = effectiveZoom(for: doc, viewport: viewport) // committed zoom (no live magnification)
        let m = pinch.magnification
        let z = zoomC * m
        let topPad = scoreTopPadding + topChromeInset
        let hPad = scoreInset(viewportWidth: viewport.width)
        let paddedW = doc.size.width + hPad * 2
        let paddedH = doc.size.height + topPad + scoreBottomPadding
        // The score applies the live pinch as `.scaleEffect(magnification, anchor: pinch.anchor)` BEFORE the committed
        // zoom, pivoting around the finger centroid. The canvas mirrors that pivot via contentOffset: a doc point p
        // lands at the same screen point as the score, which expands to
        //   screen(p) = (p + pad) * m * zoomC + anchor * (1 - m) * zoomC - scrollOffset [+ pinch.offsetX]
        // so canvas.contentOffset = scrollOffset - pad*z - anchor*(1-m)*zoomC - offsetX. The host adds the scroll
        // view's REAL contentOffset to the bias below. At rest (m == 1) the anchor term vanishes.
        let anchorTermX = pinch.anchor.x * paddedW * (1 - m) * zoomC
        let anchorTermY = pinch.anchor.y * paddedH * (1 - m) * zoomC
        // A large symmetric inset keeps the (anchor-shifted) contentOffset inside PencilKit's valid range so it is
        // never clamped during a pinch. The canvas's own pan is disabled, so the extra scroll range is unreachable.
        let slack: CGFloat = 100_000
        return AnnotationCanvasState(
            documentSize: doc.size,
            zoomScale: z,
            contentOffsetBias: CGPoint(
                x: -hPad * z - anchorTermX - pinch.offsetX,
                y: -topPad * z - anchorTermY,
            ),
            contentInset: UIEdgeInsets(top: slack, left: slack, bottom: slack, right: slack),
        )
    }

    /// User zoom scaled by a fit-to-width factor so rendered content never exceeds the viewport horizontally at
    /// user-zoom 1.0 — "zoom 1.0 = fit width", regardless of engine margins / spanners / ties / playback chrome
    /// contributing to `doc.size.width`.
    private func effectiveZoom(
        for doc: LayoutDocument, viewport: CGSize,
    ) -> CGFloat {
        // Fit the padded content (score + horizontal inset) so the inset never pushes the score past the viewport.
        let framedContentWidth = doc.size.width + scoreInset(viewportWidth: viewport.width) * 2
        let fit = framedContentWidth > 0
            ? min(1.0, viewport.width / framedContentWidth)
            : 1.0
        return viewModel.viewportZoom * fit
    }

    private func reprojectAnnotations() {
        guard let doc = document else { projectedAnnotations = PKDrawing(); return }
        projectedAnnotations = AnnotationAnchoring.display(viewModel.annotationDrawings, in: doc)
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

    /// SwiftUI `#Preview` snapshots the view tree before the async `.task` (which hops to a detached background
    /// `LayoutEngine.layout`) completes, so `document` is still nil and the score area renders blank. When running
    /// under Xcode Previews, lay the score out synchronously on first appearance so the snapshot has a populated
    /// `document`. No-op in the real app / live capture (those let the async path run and never enter this branch).
    private func eagerLayoutIfNeeded(width: CGFloat) {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" else { return }
        // Re-lay out whenever the width changes (not only when nil): `onAppear` can fire before the GeometryReader
        // settles to its final width, so the first synchronous layout may be narrower than the viewport (leaving a
        // right-side gap). Re-running on width change ensures the snapshot uses the settled width and fills the view.
        guard document == nil || width != lastWidth else { return }
        let newDoc = LayoutEngine.layout(score: score, options: scoreOptions, availableWidth: width)
        document = newDoc
        editingHost?.document = newDoc
        lastWidth = width
    }

    private func rebuildLayout(width: CGFloat) async {
        // Runs off the main actor on `relayoutEngine`'s executor (this task is already `.userInitiated`, the default
        // for `.task`), so the engrave keeps its old priority without a second detached hop — and, unlike the detached
        // task it replaces, it can reuse the previous engrave's `LayoutCache`.
        let newDoc = await relayoutEngine.layout(
            score: score, options: scoreOptions, availableWidth: width,
        )
        guard !Task.isCancelled else { return }
        document = newDoc
        editingHost?.document = newDoc
        lastWidth = width
    }

    private func autoScroll(
        realCursor: ScoreCursor?,
        lookaheadCursor: ScoreCursor?,
        viewport: CGSize,
    ) {
        guard let realCursor, let doc = document,
              let realRect = doc.cursorFrame(for: realCursor, in: score)
        else { return }

        let zoom = effectiveZoom(for: doc, viewport: viewport)
        let pad = 8 * doc.metrics.sp * zoom

        // Frames in scroll-content coords: scaled from top-leading. Mirrors `VerticalZoomedSurface`'s composition —
        // vertical padding on top/bottom, and (on iPad) a horizontal inset that shifts the score's content-space x
        // rightward before scaling. `cursorFrame` spans every staff in the system, so its Y range is the system span.
        let topPad = scoreTopPadding + topChromeInset
        let hPad = scoreInset(viewportWidth: viewport.width)
        let realMinX = (realRect.minX + hPad) * zoom
        let realMaxX = (realRect.maxX + hPad) * zoom
        let realMinY = (realRect.minY + topPad) * zoom
        let realMaxY = (realRect.maxY + topPad) * zoom

        let curX = liveScrollOffset.x
        let curY = liveScrollOffset.y

        // Horizontal follow is unchanged — keep the playing cursor's column in view (only relevant when zoomed).
        let newX = adjustedScrollOffset(
            currentOffset: curX,
            targetMin: realMinX, targetMax: realMaxX,
            viewportSize: viewport.width, pad: pad,
        )

        let newY: CGFloat
        if let lookaheadCursor, let lookRect = doc.cursorFrame(for: lookaheadCursor, in: score) {
            // Playback: pin the playing cursor's system to the top, re-scrolling only when that system or the
            // lookahead (a couple beats ahead) leaves the viewport — so the cursor drifts down between scrolls.
            // The pinned system top lands `chromeClearance` points below the screen top — clear of the Reader's
            // self-drawn top bar, which `topChromeInset` measures. This is a SCREEN-space distance (not
            // zoom-scaled): `contentOffset` shares the scaled-content point space, so the system top appears at
            // screen-y == `chromeClearance` regardless of zoom. The 8 pt gap keeps the staff off the toolbar's glass.
            let lookMaxY = (lookRect.maxY + topPad) * zoom
            let chromeClearance = topChromeInset + 8
            newY = CGFloat(scrollOffsetPinningSystemTop(
                current: Double(curY),
                systemMin: Double(realMinY),
                systemMax: Double(realMaxY),
                lookaheadMax: Double(lookMaxY),
                viewport: Double(viewport.height),
                topInset: Double(chromeClearance),
            ))
        } else {
            // Paused / scrubbing / manual seek: gentle keep-in-view so a tap-to-seek doesn't jump the system to top.
            newY = adjustedScrollOffset(
                currentOffset: curY,
                targetMin: realMinY, targetMax: realMaxY,
                viewportSize: viewport.height, pad: pad,
            )
        }

        if abs(newX - curX) < 0.5, abs(newY - curY) < 0.5 {
            return
        }

        pendingScroll = .animated(CGPoint(x: newX, y: newY))
    }

    /// Smallest scroll offset that keeps `[targetMin, targetMax]` inside the viewport with `pad` margin. Returns
    /// `currentOffset` unchanged when the target is already fully visible — preserves manual horizontal panning while
    /// playback advances within the visible row. Delegates to the shared `Domain.scrollOffsetKeepingInView` so iOS
    /// and Android follow the cursor identically (parity: one implementation, no divergent Kotlin port).
    private func adjustedScrollOffset(
        currentOffset cur: CGFloat,
        targetMin: CGFloat,
        targetMax: CGFloat,
        viewportSize: CGFloat,
        pad: CGFloat,
    ) -> CGFloat {
        CGFloat(scrollOffsetKeepingInView(
            current: Double(cur),
            targetMin: Double(targetMin),
            targetMax: Double(targetMax),
            viewport: Double(viewportSize),
            pad: Double(pad),
        ))
    }

    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let width: CGFloat
        let honorLayoutBreaks: Bool
        let collapseMultiMeasureRests: Bool
        let showInvisibleElements: Bool
        let showAllMeasureNumbers: Bool
        let transposeSemitones: Int
        /// `ReaderEditingHost.editGeneration`, bumped by the editing surface on every edit that needs a relayout.
        /// `scoreSignature` only tracks STRUCTURAL shape (part/staff counts, division, opening clefs) — a pitch
        /// change or other in-place note edit leaves it unchanged even though `score`'s contents differ, so without
        /// this field the `.task(id:)` would never re-run after such an edit. `0` when not editing.
        let editGeneration: Int

        init(
            score: Score,
            size: CGFloat,
            width: CGFloat,
            honorLayoutBreaks: Bool,
            collapseMultiMeasureRests: Bool,
            showInvisibleElements: Bool,
            showAllMeasureNumbers: Bool,
            transposeSemitones: Int,
            editGeneration: Int,
        ) {
            // `Score` is Equatable but not Hashable. Use a cheap identity proxy: structural shape + opening clefs.
            // The opening-clef hash is what makes a clef override (a field-level edit that leaves parts.count / staff
            // count unchanged) re-trigger this `.task(id:)`.
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
            self.editGeneration = editGeneration
        }
    }
}
