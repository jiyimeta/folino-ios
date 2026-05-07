import SwiftUI

extension View {
    /// Platform-aware toolbar wiring for `ReaderView`. iOS hides the
    /// navigation bar entirely (the buttons are rendered as a floating
    /// `ReaderTopOverlay`); macOS keeps the conventional toolbar items.
    /// Lives in a `View` extension so the call site stays a flat
    /// modifier chain — embedding `#if` directly in `ReaderView`'s body
    /// triggers SwiftFormat ↔ SwiftLint indent oscillation.
    @ViewBuilder
    func readerToolbar(viewModel: ReaderViewModel) -> some View {
        #if os(iOS)
            toolbar(.hidden, for: .navigationBar)
        #else
            toolbar { ReaderToolbar(viewModel: viewModel) }
        #endif
    }
}

#if os(iOS)
    /// Top overlay hosting Back / Play / Inspector buttons on iOS. Rendered
    /// inside `ReaderView`'s `ZStack` so the score stays visible behind the
    /// buttons — maximising the rendered staff area, which is core to the
    /// app's value proposition.
    ///
    /// We sidestep the standard `.toolbar { … }` route because on iOS 26.3.x
    /// physical devices `.toolbarBackgroundVisibility(.hidden, for: .navigationBar)`
    /// fails to suppress the navigation bar's chrome (confirmed working only
    /// from iOS 26.4 simulator). Once 26.4+ adoption is broad, this overlay
    /// can likely be reverted to a plain `ToolbarContent`.
    struct ReaderTopOverlay: View {
        @Bindable var viewModel: ReaderViewModel
        let onBack: () -> Void

        /// Vertical space the overlay occupies inside the safe area
        /// (button 40 + top padding 4 + a little breathing room). Used by
        /// `ReaderView` to extend the score's safe area so the first
        /// staff is never hidden under the floating buttons.
        static let height: CGFloat = 52

        var body: some View {
            HStack(spacing: 12) {
                overlayButton(
                    systemImage: "chevron.backward",
                    label: Text("Back", bundle: .module),
                    action: onBack
                )
                .glassEffect(.regular.interactive())
                Spacer()
                HStack(spacing: 4) {
                    overlayButton(
                        systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill",
                        label: Text(viewModel.isPlaying ? "Pause" : "Play", bundle: .module)
                    ) {
                        Task { await viewModel.togglePlayback() }
                    }
                    overlayButton(
                        systemImage: "slider.horizontal.3",
                        label: Text("Show staves panel", bundle: .module)
                    ) {
                        viewModel.isInspectorPresented.toggle()
                    }
                }
                .glassEffect(.regular.interactive())
            }
            .padding(.horizontal)
            .padding(.top, 4)
        }

        @ViewBuilder
        private func overlayButton(
            systemImage: String,
            label: Text,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .tint(.primary)
            .accessibilityLabel(label)
        }
    }
#else
    /// macOS keeps the conventional toolbar — the iOS-26.3.x bug doesn't apply,
    /// and the platform's window chrome is the natural home for these actions.
    struct ReaderToolbar: ToolbarContent {
        @Bindable var viewModel: ReaderViewModel

        var body: some ToolbarContent {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await viewModel.togglePlayback() }
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(Text(viewModel.isPlaying ? "Pause" : "Play", bundle: .module))

                Button {
                    viewModel.isInspectorPresented.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel(Text("Show staves panel", bundle: .module))
            }
        }
    }
#endif

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
                    Label {
                        Text("Reset zoom", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            Spacer()
        }
        .padding()
    }
}
