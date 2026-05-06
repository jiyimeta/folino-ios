import Domain
import SheetMusicCore
import SwiftUI

@MainActor
public struct ReaderView: View {
    @State private var viewModel: ReaderViewModel
    @Environment(\.horizontalSizeClass) private var _horizontalSizeClass

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL,
        playbackController: (any PlaybackController)? = nil
    ) {
        // Seed the device-class default at construction time. The view
        // model only uses this if no persisted record exists.
        let initialDefault: CGFloat = 14 // TBD: device-class override (follow-up)
        _viewModel = State(
            wrappedValue: ReaderViewModel(
                scoreItem: scoreItem,
                repository: repository,
                gateway: gateway,
                scoresDirectory: scoresDirectory,
                defaultStaffSize: initialDefault,
                playbackController: playbackController
            )
        )
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            content
            ReaderBottomOverlay(viewModel: viewModel)
        }
        .navigationTitle(viewModel.scoreItem.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ReaderToolbar(viewModel: viewModel)
            }
            .inspector(isPresented: $viewModel.isInspectorPresented) {
                if case let .loaded(score) = viewModel.loadState {
                    MixerView(viewModel: viewModel, score: score)
                        .presentationDetents([.medium, .large])
                } else {
                    Color.clear
                }
            }
            .alert(
                "Loading playback sounds…",
                isPresented: Binding(
                    get: { viewModel.isLoadingSoundfonts },
                    set: { newValue in
                        if !newValue { viewModel.cancelLoadingSoundfonts() }
                    }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    viewModel.cancelLoadingSoundfonts()
                }
            }
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView().controlSize(.large)
        case let .loaded(score):
            let visible = score.filtered(hidingStaves: viewModel.preferences.hiddenStaves)
            ReaderGestureLayer(viewModel: viewModel) {
                VerticalScoreContainer(
                    score: visible,
                    staffSize: viewModel.preferences.staffSize,
                    playbackCursor: viewModel.playbackCursor,
                    viewModel: viewModel
                )
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Could not open this score", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await viewModel.load() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

#if DEBUG
    /// Documents the shape of a real Score fixture. Not used by the previews
    /// below — building a `ReaderView` preview requires wiring a fake gateway
    /// that returns a real `Score`, which is too brittle for a preview. See
    /// `MixerView` for a productive Score-shaped preview.
    @MainActor
    private func previewScore() -> Score {
        Score(
            division: 480,
            parts: [],
            metaTags: ["workTitle": "Sample"]
        )
    }

    #Preview("Loading") {
        ProgressView().controlSize(.large)
    }

    #Preview("Loaded · vertical · iPhone") {
        // A real assembled-ReaderView preview would need a fake gateway
        // returning a non-empty Score plus persistence wiring. Snapshot the
        // chrome-only intent here; productive Score shape lives in
        // `MixerView`'s preview.
        Text("Run via xcode preview to see the assembled view")
    }
#endif
