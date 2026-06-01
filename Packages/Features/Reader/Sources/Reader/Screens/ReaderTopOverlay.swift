import SheetMusicCore
import SwiftUI

/// Top overlay hosting Back / Inspector buttons. Rendered inside `ReaderRootScreen`'s `ZStack` so the score
/// stays visible behind the buttons — maximising the rendered staff area, which is core to the app's value proposition.
///
/// We sidestep the standard `.toolbar { … }` route because on iOS 26.3.x physical devices
/// `.toolbarBackgroundVisibility(.hidden, for: .navigationBar)` fails to suppress the navigation bar's chrome
/// (confirmed working only from iOS 26.4 simulator). Once 26.4+ adoption is broad, this overlay can likely be reverted
/// to a plain `ToolbarContent`.
struct ReaderTopOverlay: View {
    @Bindable var viewModel: ReaderViewModel
    /// `nil` hides the back button entirely — used by iPad split-view detail where the sidebar already provides
    /// navigation back to the library.
    let onBack: (() -> Void)?

    /// Vertical space the overlay occupies inside the safe area (button 40 + top padding 4 + a little breathing room).
    /// Used by `ReaderRootScreen` to extend the score's safe area so the first staff is never hidden under the floating
    /// buttons.
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

    /// Right-side buttons that depend on a loaded score: the paired inspector pill. Play/pause moved to the bottom
    /// transport control (`ReaderTransportControl`) so the primary transport controls sit within thumb reach. Extracted
    /// from `body` to keep the outer HStack closure under SwiftLint's body-length limit.
    private func loadedActions(score: Score) -> some View {
        inspectorButtons(score: score)
            .glassEffect(.regular.interactive())
    }

    /// Paired playback / visual inspector buttons sharing a single glass-pill background. Each button owns its own
    /// popover anchored to itself so the popover arrow points at the tapped icon.
    private func inspectorButtons(score: Score) -> some View {
        HStack(spacing: 0) {
            overlayButton(
                systemImage: "slider.vertical.3",
                label: Text("reader.toolbar.showPlaybackSettings", bundle: .module),
            ) {
                viewModel.isPlaybackInspectorPresented.toggle()
            }
            .popover(isPresented: $viewModel.isPlaybackInspectorPresented) {
                PlaybackInspectorScreen(
                    mixerModel: viewModel.mixerModel,
                    tempoModel: viewModel.tempoModel,
                    masterVolumeModel: viewModel.masterVolumeModel,
                    repeatModel: viewModel.repeatModel,
                    score: score,
                    playbackCursor: viewModel.playbackSession.playbackCursor,
                )
                .frame(idealWidth: 380, idealHeight: 600)
                .presentationDetents([.large])
                .presentationCompactAdaptation(.sheet)
            }

            overlayButton(
                systemImage: "text.page",
                label: Text("reader.toolbar.showDisplaySettings", bundle: .module),
            ) {
                viewModel.isVisualInspectorPresented.toggle()
            }
            .popover(isPresented: $viewModel.isVisualInspectorPresented) {
                VisualInspectorScreen(
                    layoutModel: viewModel.layoutModel,
                    score: score,
                )
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
