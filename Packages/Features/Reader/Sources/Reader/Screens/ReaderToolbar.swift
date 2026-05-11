import SheetMusicCore
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
                    action: onBack,
                )
                .glassEffect(.regular.interactive())
            }
            Spacer()

            if case let .loaded(score) = viewModel.loadState {
                loadedActions(score: score)
            }
        }
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// Right-side buttons that depend on a loaded score: play/pause plus
    /// the paired inspector pill. Extracted from `body` to keep the outer
    /// HStack closure under SwiftLint's body-length limit.
    private func loadedActions(score: Score) -> some View {
        HStack(spacing: 12) {
            overlayButton(
                systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill",
                label: Text(
                    viewModel.isPlaying ? "reader.toolbar.pause" : "reader.toolbar.play",
                    bundle: .module,
                ),
            ) {
                Task { await viewModel.togglePlayback() }
            }
            .glassEffect(.regular.interactive())

            inspectorButtons(score: score)
                .glassEffect(.regular.interactive())
        }
    }

    /// Paired playback / visual inspector buttons sharing a single
    /// glass-pill background. Each button owns its own popover anchored
    /// to itself so the popover arrow points at the tapped icon.
    private func inspectorButtons(score: Score) -> some View {
        HStack(spacing: 0) {
            overlayButton(
                systemImage: "slider.vertical.3",
                label: Text("reader.toolbar.showPlaybackSettings", bundle: .module),
            ) {
                viewModel.isPlaybackInspectorPresented.toggle()
            }
            .popover(isPresented: $viewModel.isPlaybackInspectorPresented) {
                PlaybackInspectorScreen(viewModel: viewModel, score: score)
                    .frame(idealWidth: 380, idealHeight: 600)
                    .presentationDetents([.medium, .large])
                    .presentationCompactAdaptation(.sheet)
            }

            overlayButton(
                systemImage: "text.page",
                label: Text("reader.toolbar.showDisplaySettings", bundle: .module),
            ) {
                viewModel.isVisualInspectorPresented.toggle()
            }
            .popover(isPresented: $viewModel.isVisualInspectorPresented) {
                VisualInspectorScreen(viewModel: viewModel, score: score)
                    .frame(idealWidth: 380, idealHeight: 600)
                    .presentationDetents([.medium, .large])
                    .presentationCompactAdaptation(.sheet)
            }
        }
    }

    private func overlayButton(
        systemImage: String,
        label: Text,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
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
                    onSet: { Task { await viewModel.setRepeatA() } },
                )

                endpointButton(
                    label: "B",
                    isSet: viewModel.pendingRepeatB != nil,
                    onSet: { Task { await viewModel.setRepeatB() } },
                )
            }
        }
        .padding()
    }

    private func endpointButton(
        label: String,
        isSet: Bool,
        onSet: @escaping () -> Void,
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

#if DEBUG
    #Preview {
        let vm = ReaderViewModel(
            scoreItem: PreviewFakeRepository.sampleItem,
            repository: PreviewFakeRepository(),
            gateway: PreviewFakeGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
        )
        ReaderTopOverlay(viewModel: vm, onBack: {})
            .task {
                await vm.load()
            }
    }
#endif
