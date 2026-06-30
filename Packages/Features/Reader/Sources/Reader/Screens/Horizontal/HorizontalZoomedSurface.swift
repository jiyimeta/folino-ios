import SheetMusicUI
import SwiftUI

/// The hosted score subtree. Lives inside `ScoreScrollHost`'s `UIHostingController`. Reads `pinch.*` and
/// `viewModel.viewportZoom` directly so SwiftUI observation can deliver animated updates inside the host — the parent
/// `HorizontalScoreContainer` body never touches these, so it doesn't re-render and the hostingController doesn't
/// reassign its `rootView` on every gesture frame.
struct HorizontalZoomedSurface: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    let document: LayoutDocument?
    let score: Score
    let viewport: CGSize
    let scorePadding: CGFloat
    let scoreOptions: ScoreViewOptions
    let playbackCursor: ScoreCursor?
    @Binding var lastManualCursor: ScoreCursor?

    var body: some View {
        if let doc = document {
            let zoom = viewModel.viewportZoom
            let framedWidth = (doc.size.width + scorePadding * 2) * zoom
            let framedHeight = (doc.size.height + scorePadding * 2) * zoom
            scoreSurface(document: doc)
                .padding(scorePadding)
                .scaleEffect(pinch.magnification, anchor: pinch.anchor)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(x: 0, y: pinch.offsetY)
                // Single frame at the framed (zoomed) size. Vertical centering when the score is shorter than the
                // viewport is handled by `UIScrollView.contentInset` in `ScoreScrollHost` — a second outer
                // `.frame(max(...))` would inflate `hostView.bounds` and desync the pinch anchor.
                .frame(
                    width: framedWidth,
                    height: framedHeight,
                    alignment: .topLeading,
                )
        } else {
            Color.clear
        }
    }

    private func scoreSurface(document doc: LayoutDocument) -> some View {
        ZStack(alignment: .topLeading) {
            ScoreView(
                document: doc, score: score, options: scoreOptions,
                playbackCursor: playbackCursor, playbackCursorColor: .accentColor.opacity(0.6),
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
    }

    private func tapSeekGesture(document: LayoutDocument) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named("scoreSurface"))
            .onEnded { value in
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.playbackSession.setManualCursor(cursor)
                lastManualCursor = cursor
            }
    }
}
