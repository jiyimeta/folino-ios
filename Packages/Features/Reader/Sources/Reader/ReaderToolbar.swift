import SwiftUI

/// Trailing toolbar contents and the bottom reset-zoom pill for the
/// Reader. Hosted from `ReaderView`'s `.toolbar { … }` modifier.
struct ReaderToolbar: ToolbarContent {
    @Bindable var viewModel: ReaderViewModel

    private var trailingPlacement: ToolbarItemPlacement {
        #if os(iOS)
            .topBarTrailing
        #else
            .primaryAction
        #endif
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: trailingPlacement) {
            Button {
                Task { await viewModel.togglePlayback() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Button {
                viewModel.isInspectorPresented.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Show staves panel")
        }
    }
}

/// Bottom reset-zoom pill. Lives outside the toolbar so it can sit on
/// top of the score content rather than in the navigation bar.
struct ReaderBottomOverlay: View {
    @Bindable var viewModel: ReaderViewModel

    var body: some View {
        HStack {
            if viewModel.viewportZoom > 1.0 {
                Button {
                    viewModel.resetZoom()
                } label: {
                    Label("Reset zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            Spacer()
        }
        .padding()
    }
}
