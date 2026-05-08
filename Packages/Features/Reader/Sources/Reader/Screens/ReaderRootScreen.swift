import Domain
import SheetMusicCore
import SwiftUI
import UtilityUI

@MainActor
public struct ReaderRootScreen: View {
    @State private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    private let onBack: (() -> Void)?

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL,
        playbackController: (any PlaybackController)? = nil,
        reachability: (any NetworkReachability)? = nil,
        onBack: (() -> Void)? = nil
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
                playbackController: playbackController,
                reachability: reachability
            )
        )
        self.onBack = onBack
    }

    public var body: some View {
        ZStack {
            #if os(iOS)
                content
                    .safeAreaPadding(.top, ReaderTopOverlay.height)
            #else
                content
            #endif
            VStack(spacing: 0) {
                #if os(iOS)
                    ReaderTopOverlay(
                        viewModel: viewModel,
                        onBack: onBack ?? { dismiss() }
                    )
                #endif
                Spacer()
                ReaderBottomOverlay(viewModel: viewModel)
            }
        }
        .navigationTitle("")
        .readerToolbar(viewModel: viewModel)
        .inspector(isPresented: $viewModel.isInspectorPresented) {
            if case let .loaded(score) = viewModel.loadState {
                InspectorScreen(viewModel: viewModel, score: score)
                    .presentationDetents([.medium, .large])
            } else {
                Color.clear
            }
        }
        .alert(
            soundfontAlertTitle(for: viewModel.soundfontAlertKind),
            isPresented: Binding(
                get: { viewModel.soundfontAlertKind != nil },
                set: { newValue in
                    if !newValue { viewModel.cancelLoadingSoundfonts() }
                }
            )
        ) {
            Button(role: .cancel) {
                viewModel.cancelLoadingSoundfonts()
            } label: {
                L10n.Common.cancel
            }
        }
        .task {
            viewModel.startObservingCursor()
            await viewModel.load()
            await viewModel.prepareForPlayback()
        }
    }

    private func soundfontAlertTitle(
        for kind: ReaderViewModel.SoundfontAlertKind?
    ) -> String {
        switch kind {
        case .offline:
            String(localized: "reader.error.offline", bundle: .module)
        case .loading, nil:
            String(localized: "reader.playback.loadingSounds", bundle: .module)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView().controlSize(.large)
        case let .loaded(score):
            let visible = score.filtered(hidingStaves: viewModel.preferences.hiddenStaves)
            switch viewModel.layoutMode {
            case .vertical:
                VerticalScoreContainer(
                    score: visible,
                    staffSize: viewModel.preferences.staffSize,
                    honorLayoutBreaks: viewModel.preferences.honorLayoutBreaks,
                    playbackCursor: viewModel.playbackCursor,
                    viewModel: viewModel
                )
            case .horizontal:
                HorizontalScoreContainer(
                    score: visible,
                    staffSize: viewModel.preferences.staffSize,
                    honorLayoutBreaks: viewModel.preferences.honorLayoutBreaks,
                    playbackCursor: viewModel.playbackCursor,
                    viewModel: viewModel
                )
            }
        case let .failed(message):
            ContentUnavailableView {
                Label {
                    Text("reader.error.cannotOpen.title", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(message)
            } actions: {
                Button { Task { await viewModel.load() } } label: {
                    Text("reader.error.retry", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

#if DEBUG
    /// Documents the shape of a real Score fixture. Not used by the previews
    /// below — building a `ReaderRootScreen` preview requires wiring a fake gateway
    /// that returns a real `Score`, which is too brittle for a preview. See
    /// `InspectorScreen` for a productive Score-shaped preview.
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
        // A real assembled-ReaderRootScreen preview would need a fake gateway
        // returning a non-empty Score plus persistence wiring. Snapshot the
        // chrome-only intent here; productive Score shape lives in
        // `InspectorScreen`'s preview.
        Text("Run via xcode preview to see the assembled view")
    }
#endif
