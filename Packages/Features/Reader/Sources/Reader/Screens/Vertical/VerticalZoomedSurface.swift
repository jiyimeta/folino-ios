// PARITY(macos): vertical mode's note-editing overlay — this is the subtree `VerticalScoreContainer` hosts, and the
//   `EditingSelectionOverlay` / tap-routing it carries is the half of that container's debt which lives at this
//   layer. `MacVerticalScoreContainer` draws the same score without it, and Ⅳ is where it arrives.

#if os(iOS)
import SheetMusicUI
import SwiftUI

/// The hosted score subtree. Lives inside `ScoreScrollHost`'s `UIHostingController`. Reads `pinch.*` and
/// `viewModel.viewportZoom` directly so SwiftUI observation can deliver animated updates inside the host — the parent
/// `VerticalScoreContainer` body never touches these, so it doesn't re-render and the hostingController doesn't
/// reassign its `rootView` on every gesture frame.
struct VerticalZoomedSurface: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    let document: LayoutDocument?
    let score: Score
    let viewport: CGSize
    /// Horizontal inset on each side of the score (iPad only; 0 on iPhone). Lives inside the scaled content so it
    /// scales with zoom, matching the top / bottom padding. See `VerticalScoreContainer.scoreInset`.
    let horizontalPadding: CGFloat
    let scoreTopPadding: CGFloat
    let scoreBottomPadding: CGFloat
    /// Total top chrome inset — status bar plus the Reader's self-drawn top bar (`ReaderTopBar`). See
    /// `VerticalScoreContainer.topChromeInset`.
    let topChromeInset: CGFloat
    let scoreOptions: ScoreViewOptions
    let playbackCursor: ScoreCursor?
    @Binding var lastManualCursor: ScoreCursor?
    /// `nil` (or `isEditing == false`) keeps taps on the manual-cursor seek path and the score render byte-identical
    /// to before editing existed. While editing, taps route to `editingHost.onTap` instead, `ScoreView` renders
    /// the host's selection, and `EditingSelectionOverlay` draws the caret / rest tint / pitch-drag chrome on top.
    let editingHost: ReaderEditingHost?

    var body: some View {
        if let doc = document {
            let zoom = effectiveZoom(for: doc)
            let topPad = scoreTopPadding + topChromeInset
            let framedWidth = (doc.size.width + horizontalPadding * 2) * zoom
            let framedHeight = (doc.size.height + topPad + scoreBottomPadding) * zoom
            scoreSurface(document: doc)
                .padding(.top, topPad)
                .padding(.bottom, scoreBottomPadding)
                .padding(.horizontal, horizontalPadding)
                .scaleEffect(pinch.magnification, anchor: pinch.anchor)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(x: pinch.offsetX, y: 0)
                .frame(
                    width: framedWidth,
                    height: framedHeight,
                    alignment: .topLeading,
                )
                .background(editingDeselectCatcher(host: editingHost))
        } else {
            Color.clear
        }
    }

    private func effectiveZoom(for doc: LayoutDocument) -> CGFloat {
        // Fit the padded content (score + horizontal inset) into the viewport so the inset score never overflows.
        let framedContentWidth = doc.size.width + horizontalPadding * 2
        let fit = framedContentWidth > 0
            ? min(1.0, viewport.width / framedContentWidth)
            : 1.0
        return viewModel.viewportZoom * fit
    }

    private func scoreSurface(document doc: LayoutDocument) -> some View {
        ZStack(alignment: .topLeading) {
            ScoreView(
                document: doc, score: score, options: scoreOptions,
                // `displaySelection`, not `selection`: the editor addresses the unfiltered score, this document is
                // laid out from the staff-filtered one. See `ReaderEditingHost.displayItem(for:)`.
                selection: editingHost?.isEditing == true ? (editingHost?.displaySelection ?? .none) : .none,
                voiceColors: ReaderEditingPresentation.voiceColors,
                playbackCursor: playbackCursor, playbackCursorColor: .accentColor.opacity(0.6),
            )
            .gesture(tapSeekGesture(document: doc))
            .sensoryFeedback(.impact(weight: .medium), trigger: lastManualCursor)

            // NOTE: the annotation canvas is intentionally NOT here. A PKCanvasView sized to the full score height
            // overflows PencilKit's live-stroke render surface (its bounds*screenScale exceeds the Metal texture
            // limit), enlarging the in-progress stroke. It is mounted as a viewport-sized top-level overlay in
            // `VerticalScoreContainer.annotationOverlay`, with PencilKit owning the document scroll/zoom.

            if viewModel.repeatModel.mode == .abLoop {
                LoopRegionOverlay(document: doc, range: viewModel.repeatModel.abRange)
                LoopBoundaryMarkers(
                    document: doc,
                    start: viewModel.repeatModel.pendingRepeatA,
                    end: viewModel.repeatModel.pendingRepeatB,
                )
            }

            // Last in the stack — over `ScoreView`, which paints itself opaque white and would hide anything beneath
            // it. The caret gets there by blending (`EditingSelectionOverlay`), not by z-order.
            if let host = editingHost, host.isEditing {
                EditingSelectionOverlay(host: host, score: score, document: doc)
            }
        }
        .coordinateSpace(name: "scoreSurface")
    }

    private func tapSeekGesture(document: LayoutDocument) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named("scoreSurface"))
            .onEnded { value in
                if let host = editingHost, host.wantsScoreTaps {
                    host.onTap(value.location)
                    return
                }
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.playbackSession.setManualCursor(cursor)
                lastManualCursor = cursor
                editingHost?.rememberTappedItem(cursor)
            }
    }
}
#endif
