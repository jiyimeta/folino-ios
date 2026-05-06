import SwiftUI

/// Wraps Reader content in pinch / pan / double-tap zoom gestures.
/// Single-tap is intentionally left to the inner score surface so it can
/// drive cursor seeking without conflicting with `ScrollView`.
///
/// Gesture rules per the spec:
///   - Pinch: drives `viewportZoom`. Snap to 1.0 when ending below 1.05.
///   - One-finger drag: pans only when `viewportZoom > 1.0`.
///   - Double tap: toggles 1.0 ⇄ last non-unit zoom.
struct ReaderGestureLayer<Content: View>: View {
    @Bindable var viewModel: ReaderViewModel
    @ViewBuilder let content: () -> Content

    @GestureState private var liveMagnification: CGFloat = 1.0
    @GestureState private var liveDragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { _ in
            content()
                .scaleEffect(viewModel.viewportZoom * liveMagnification, anchor: .center)
                .offset(
                    x: viewModel.viewportPan.width + liveDragTranslation.width,
                    y: viewModel.viewportPan.height + liveDragTranslation.height
                )
                .contentShape(Rectangle())
                .gesture(magnifyGesture)
                .simultaneousGesture(panGesture)
                .simultaneousGesture(doubleTapGesture)
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

    private var panGesture: some Gesture {
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

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { _ in
                viewModel.toggleZoom(targetIfZoomedOut: 2.0)
            }
    }
}
