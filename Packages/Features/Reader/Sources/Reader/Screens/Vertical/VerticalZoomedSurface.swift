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
    let safeAreaTop: CGFloat
    let scoreOptions: ScoreViewOptions
    let playbackCursor: ScoreCursor?
    @Binding var lastManualCursor: ScoreCursor?

    var body: some View {
        if let doc = document {
            let zoom = effectiveZoom(for: doc)
            let topPad = scoreTopPadding + safeAreaTop
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
                playbackCursor: playbackCursor, playbackCursorColor: .accentColor,
            )
            .coordinateSpace(name: "scoreSurface")
            .gesture(tapSeekGesture(document: doc))
            .sensoryFeedback(.impact(weight: .medium), trigger: lastManualCursor)

            AnnotationCanvasView(
                documentSize: doc.size,
                drawingData: viewModel.annotationDrawingData,
                isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
                onChange: { data, isEmpty in viewModel.annotationDrawingDidChange(data, isEmpty: isEmpty) },
            )
            .frame(width: doc.size.width, height: doc.size.height, alignment: .topLeading)
            .allowsHitTesting(viewModel.isAnnotating)

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
