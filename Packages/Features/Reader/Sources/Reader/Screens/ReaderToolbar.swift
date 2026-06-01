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
    /// overlay (`ReaderBottomOverlay`) so the primary transport controls sit within thumb reach. Extracted from `body`
    /// to keep the outer HStack closure under SwiftLint's body-length limit.
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

/// Bottom overlay hosting the transport control. When `showSeekBar` is true it renders a full-width
/// glass card (seek bar over the transport row); when false it keeps the compact right-aligned pill.
/// Lives outside the toolbar so it sits on top of the score and keeps the transport within thumb reach.
struct ReaderBottomOverlay: View {
    @Bindable var viewModel: ReaderViewModel
    /// When true, render the full-width seek-bar card; when false, the compact transport pill.
    let showSeekBar: Bool

    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    /// Content height (above the bottom safe area) of the compact control — transport pill (44) plus
    /// the surrounding `.padding()` (16 top + 16 bottom). Used by `ReaderRootScreen` to inset the
    /// horizontal / page viewport so the score never renders under the control.
    static let collapsedContentHeight: CGFloat = 76
    /// Content height of the expanded card — seek row (~28) + spacing (8) + transport row (44) plus
    /// top padding (12) and bottom padding (8). Excludes the safe-area bleed region.
    static let expandedContentHeight: CGFloat = 100

    private var loadedScore: Score? {
        if case let .loaded(score) = viewModel.loadState { return score }
        return nil
    }

    var body: some View {
        if showSeekBar, let score = loadedScore {
            expandedLayout(score: score)
        } else {
            collapsedLayout
        }
    }

    // MARK: Collapsed (today's layout)

    private var collapsedLayout: some View {
        HStack(spacing: 12) {
            resetZoomButton
            Spacer()
            endpointButtons
            if case .loaded = viewModel.loadState {
                transportPill
            }
        }
        .padding()
    }

    // MARK: Expanded (full-width seek card)

    private func expandedLayout(score: Score) -> some View {
        VStack(spacing: 8) {
            if viewModel.viewportZoom > 1.0 {
                HStack { resetZoomButton; Spacer() }
                    .padding(.horizontal)
            }
            seekCard(score: score)
        }
    }

    private func seekCard(score: Score) -> some View {
        VStack(spacing: 8) {
            seekBar(score: score)
            HStack(spacing: 0) {
                transportButtonsContent
                Spacer(minLength: 0)
                endpointButtons
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .ignoresSafeArea(edges: .bottom)
        }
        .padding(.horizontal, 12)
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }

    private func seekBar(score: Score) -> some View {
        let total = score.notatedDurationSeconds
        let fraction = Binding<Double>(
            get: {
                if isScrubbing { return scrubFraction }
                guard total > 0, let cursor = viewModel.playbackSession.playbackCursor else { return 0 }
                return min(max(score.seconds(at: cursor) / total, 0), 1)
            },
            set: { newValue in
                scrubFraction = newValue
                viewModel.playbackSession.updateScrub(toFraction: newValue)
            },
        )
        return Slider(value: fraction, in: 0 ... 1) { editing in
            isScrubbing = editing
            if editing {
                viewModel.playbackSession.beginScrub()
            } else {
                viewModel.playbackSession.endScrub()
            }
        }
        .tint(.accentColor)
        .accessibilityLabel(Text("reader.toolbar.seekBar", bundle: .module))
    }

    // MARK: Shared pieces

    @ViewBuilder private var resetZoomButton: some View {
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
    }

    @ViewBuilder private var endpointButtons: some View {
        if viewModel.repeatModel.mode == .abLoop {
            endpointButton(
                label: "A",
                isSet: viewModel.repeatModel.pendingRepeatA != nil,
                onSet: { Task { await viewModel.repeatModel.setA() } },
            )
            endpointButton(
                label: "B",
                isSet: viewModel.repeatModel.pendingRepeatB != nil,
                onSet: { Task { await viewModel.repeatModel.setB() } },
            )
        }
    }

    private var transportPill: some View {
        HStack(spacing: 0) { transportButtonsContent }
            .glassEffect(.regular.interactive())
            .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }

    /// Primary transport buttons: jump-to-start, step back a measure, play/pause, step forward a measure. Shared
    /// between the collapsed pill and the expanded card so the two layouts stay in sync.
    @ViewBuilder private var transportButtonsContent: some View {
        // Same glyph as page mode's "jump to first page" tap zone — a custom symbol bundled with the Reader module
        // (`PageTapZoneKind.first`), since no system SF Symbol matches the `arrow.uturn.backward.to.line` shape.
        transportButton(
            image: Image("arrow.uturn.backward.to.line", bundle: .module),
            label: Text("reader.toolbar.jumpToStart", bundle: .module),
        ) {
            viewModel.playbackSession.seekToStart()
        }
        transportButton(
            image: Image(systemName: "chevron.left.2"),
            label: Text("reader.toolbar.stepBackward", bundle: .module),
        ) {
            viewModel.playbackSession.stepMeasureBackward()
        }
        transportButton(
            image: Image(systemName: viewModel.playbackSession.isPlaying ? "pause.fill" : "play.fill"),
            label: Text(
                viewModel.playbackSession.isPlaying ? "reader.toolbar.pause" : "reader.toolbar.play",
                bundle: .module,
            ),
        ) {
            Task { await viewModel.playbackSession.togglePlayback() }
        }
        transportButton(
            image: Image(systemName: "chevron.right.2"),
            label: Text("reader.toolbar.stepForward", bundle: .module),
        ) {
            viewModel.playbackSession.stepMeasureForward()
        }
    }

    private func transportButton(
        image: Image,
        label: Text,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            image
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .tint(.primary)
        .accessibilityLabel(label)
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

#Preview("Bottom overlay · seek bar") {
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0",
                instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                staves: [Staff(measures: [Measure(voices: []), Measure(voices: []), Measure(voices: [])])],
            ),
        ],
        metaTags: [:],
    )
    let vm = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: PreviewFakeRepository(),
        gateway: PreviewFakeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp"),
    )
    return VStack {
        Spacer()
        ReaderBottomOverlay(viewModel: vm, showSeekBar: true)
    }
    .task { await vm.load() }
}
#endif
