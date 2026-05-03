import SwiftUI

/// Wraps Reader content in pinch / pan / tap gestures. Owns no state of
/// its own — all gesture state is bound to `ReaderViewModel` so the
/// chrome and toolbar can react in lock-step.
///
/// Gesture rules per the spec:
///   - Pinch: drives `viewportZoom`. Snap to 1.0 when ending below 1.05.
///   - One-finger drag: pans only when `viewportZoom > 1.0`.
///   - Tap: in page mode, routes to prev / chrome / next via
///     `tapZone(forX:width:)` — but only when zoom == 1.0; while zoomed,
///     center taps still toggle chrome and edge taps are inert (the user
///     uses pan).
///   - Double tap: toggles 1.0 ⇄ last non-unit zoom.
///   - Edge swipe: page-mode only, when zoom == 1.0.
struct ReaderGestureLayer<Content: View>: View {
    @Bindable var viewModel: ReaderViewModel
    let isPageMode: Bool
    let onPrevPage: () -> Void
    let onNextPage: () -> Void
    @ViewBuilder let content: () -> Content

    @GestureState private var liveMagnification: CGFloat = 1.0
    @GestureState private var liveDragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            content()
                .scaleEffect(viewModel.viewportZoom * liveMagnification, anchor: .center)
                .offset(
                    x: viewModel.viewportPan.width + liveDragTranslation.width,
                    y: viewModel.viewportPan.height + liveDragTranslation.height
                )
                .contentShape(Rectangle())
                .gesture(magnifyGesture)
                .simultaneousGesture(panGesture(width: width))
                .simultaneousGesture(tapGesture(width: width))
                .simultaneousGesture(doubleTapGesture)
                .simultaneousGesture(edgeSwipeGesture(width: width))
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($liveMagnification) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                let combined = viewModel.viewportZoom * value.magnification
                if combined < 1.05 {
                    viewModel.resetZoom()
                } else {
                    viewModel.viewportZoom = combined
                    viewModel.captureCurrentZoomAsLast()
                }
            }
    }

    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($liveDragTranslation) { value, state, _ in
                guard viewModel.viewportZoom > 1.0 else { return }
                state = value.translation
            }
            .onEnded { value in
                guard viewModel.viewportZoom > 1.0 else { return }
                viewModel.viewportPan = CGSize(
                    width: viewModel.viewportPan.width + value.translation.width,
                    height: viewModel.viewportPan.height + value.translation.height
                )
            }
    }

    private func tapGesture(width: CGFloat) -> some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                if !isPageMode || viewModel.viewportZoom > 1.0 {
                    viewModel.toggleChrome()
                    return
                }
                switch tapZone(forX: value.location.x, width: width) {
                case .prev: onPrevPage()
                case .chrome: viewModel.toggleChrome()
                case .next: onNextPage()
                }
            }
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { _ in
                viewModel.toggleZoom(targetIfZoomedOut: 2.0)
            }
    }

    private func edgeSwipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard isPageMode, viewModel.viewportZoom == 1.0 else { return }
                let edgeBand = max(width * 0.1, 40)
                let startedAtLeftEdge = value.startLocation.x < edgeBand
                let startedAtRightEdge = value.startLocation.x > width - edgeBand
                let movedRight = value.translation.width > 60
                let movedLeft = value.translation.width < -60
                if startedAtLeftEdge, movedRight { onPrevPage() }
                if startedAtRightEdge, movedLeft { onNextPage() }
            }
    }
}
