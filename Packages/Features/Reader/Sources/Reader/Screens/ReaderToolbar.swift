import SwiftUI

/// Top overlay hosting Back / Play / Inspector buttons. Rendered inside
/// `ReaderRootScreen`'s `ZStack` so the score stays visible behind the
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
    /// `nil` hides the back button entirely — used by iPad split-view detail
    /// where the sidebar already provides navigation back to the library.
    let onBack: (() -> Void)?

    /// Vertical space the overlay occupies inside the safe area
    /// (button 40 + top padding 4 + a little breathing room). Used by
    /// `ReaderRootScreen` to extend the score's safe area so the first
    /// staff is never hidden under the floating buttons.
    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                overlayButton(
                    systemImage: "chevron.backward",
                    label: Text("reader.toolbar.back", bundle: .module),
                    action: onBack
                )
                .glassEffect(.regular.interactive())
            }
            Spacer()
            HStack(spacing: 4) {
                let playLabelKey: LocalizedStringKey = viewModel.isPlaying
                    ? "reader.toolbar.pause"
                    : "reader.toolbar.play"
                overlayButton(
                    systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill",
                    label: Text(playLabelKey, bundle: .module)
                ) {
                    Task { await viewModel.togglePlayback() }
                }
                overlayButton(
                    systemImage: "slider.horizontal.3",
                    label: Text("reader.toolbar.showStaves", bundle: .module)
                ) {
                    viewModel.isInspectorPresented.toggle()
                }
                .popover(isPresented: $viewModel.isInspectorPresented) {
                    inspectorPopoverContent
                }
            }
            .glassEffect(.regular.interactive())
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// Inspector content rendered as a popover on iPad (anchored to the
    /// slider button) and adapted to a sheet on iPhone — keeps the score's
    /// width fixed so opening the inspector doesn't trigger a reflow.
    @ViewBuilder
    private var inspectorPopoverContent: some View {
        if case let .loaded(score) = viewModel.loadState {
            InspectorScreen(viewModel: viewModel, score: score)
                .frame(idealWidth: 380, idealHeight: 600)
                .presentationDetents([.medium, .large])
                .presentationCompactAdaptation(.sheet)
        } else {
            Color.clear
        }
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
                        Text("reader.toolbar.resetZoom", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            Spacer()
            if viewModel.repeatMode == .abLoop {
                endpointButton(
                    label: "A",
                    isSet: viewModel.pendingRepeatA != nil,
                    onSet: { Task { await viewModel.setRepeatA() } }
                )

                endpointButton(
                    label: "B",
                    isSet: viewModel.pendingRepeatB != nil,
                    onSet: { Task { await viewModel.setRepeatB() } }
                )
            }
        }
        .padding()
    }

    private func endpointButton(
        label: String,
        isSet: Bool,
        onSet: @escaping () -> Void
    ) -> some View {
        Button(action: onSet) {
            Text(verbatim: label)
                .tint(.primary)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.tint(isSet ? .clear : .accentColor).interactive())
    }
}
