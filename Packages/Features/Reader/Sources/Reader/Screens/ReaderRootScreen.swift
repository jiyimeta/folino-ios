import Domain
import SheetMusicCore
import SwiftUI
import UIKit
import UtilityUI

@MainActor
public struct ReaderRootScreen: View {
    @State private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    private let onBack: (() -> Void)?
    private let hidesBackButton: Bool

    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.vertical.rawValue

    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled)
    private var isMetronomeEnabled = false

    @AppStorage(ReaderGlobalSettingsKey.pictureInPictureEnabled)
    private var isPiPEnabled = false

    @AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
    private var collapseMultiMeasureRests = false

    @AppStorage(ReaderGlobalSettingsKey.keepScreenAwakeEnabled)
    private var keepScreenAwake = true

    @Environment(\.scenePhase) private var scenePhase

    private var layoutMode: ReaderLayoutMode {
        ReaderLayoutMode(rawValue: layoutModeRaw) ?? .vertical
    }

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL,
        playbackController: (any PlaybackController)? = nil,
        reachability: (any NetworkReachability)? = nil,
        onBack: (() -> Void)? = nil,
        hidesBackButton: Bool = false,
    ) {
        // Seed the device-class default at construction time. The view model only uses this if no persisted record
        // exists.
        let initialDefault: CGFloat = 14 // TBD: device-class override (follow-up)
        _viewModel = State(
            wrappedValue: ReaderViewModel(
                scoreItem: scoreItem,
                repository: repository,
                gateway: gateway,
                scoresDirectory: scoresDirectory,
                defaultStaffSize: initialDefault,
                playbackController: playbackController,
                reachability: reachability,
            ),
        )
        self.onBack = onBack
        self.hidesBackButton = hidesBackButton
    }

    public var body: some View {
        ZStack {
            content
                .safeAreaPadding(.top, ReaderTopOverlay.height)
            if viewModel.isPiPSupported {
                ScorePiPHostView(coordinator: viewModel.pipCoordinator)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                ReaderTopOverlay(
                    viewModel: viewModel,
                    onBack: hidesBackButton ? nil : (onBack ?? { dismiss() }),
                )
                Spacer()
                ReaderBottomOverlay(viewModel: viewModel)
            }
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .alert(
            soundfontAlertTitle(for: viewModel.soundfontAlertKind),
            isPresented: Binding(
                get: { viewModel.soundfontAlertKind != nil },
                set: { newValue in
                    if !newValue { viewModel.cancelLoadingSoundfonts() }
                },
            ),
        ) {
            Button(role: .cancel) {
                viewModel.cancelLoadingSoundfonts()
            } label: {
                L10n.Common.cancel
            }
        }
        .task {
            viewModel.startObservingCursor()
            viewModel.setPiPEnabled(isPiPEnabled)
            viewModel.setCollapseMultiMeasureRests(collapseMultiMeasureRests)
            await viewModel.load()
            await viewModel.prepareForPlayback()
            // Initial sync: the engine starts up unaware of persisted state, so seed it from the @AppStorage value at
            // view start.
            await viewModel.tempoModel.setMetronomeEnabled(isMetronomeEnabled)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepScreenAwake }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // `engine.prepare(score:)` ends with `AVAudioEngine.start()` + `engine.pause()`. iOS treats a running
            // engine on a `.playback` session as active audio output and would inhibit auto-lock for the rest of the
            // app's lifetime if we never tore it down. Release here so screen lock can resume once the user leaves the
            // Reader.
            let viewModel = viewModel
            Task { await viewModel.releaseEngine() }
        }
        .onChange(of: keepScreenAwake) { _, newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
        .onChange(of: isMetronomeEnabled) { _, newValue in
            // The iPad fix: if the user toggles metronome from the Settings sheet while a Reader detail pane is alive
            // in the same scene, the running engine has to be reconfigured here — the Inspector's button no longer
            // drives that side effect.
            Task { await viewModel.tempoModel.setMetronomeEnabled(newValue) }
        }
        .onChange(of: isPiPEnabled) { _, newValue in
            viewModel.setPiPEnabled(newValue)
        }
        .onChange(of: collapseMultiMeasureRests) { _, newValue in
            viewModel.setCollapseMultiMeasureRests(newValue)
        }
        .onChange(of: scenePhase) { _, newValue in
            // The Settings spec dismisses PiP whenever the app returns to the foreground, regardless of how it was
            // started.
            if newValue == .active {
                viewModel.dismissPiPOnForeground()
            }
        }
    }

    private func soundfontAlertTitle(
        for kind: ReaderViewModel.SoundfontAlertKind?,
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
            let withClefs = score.applying(clefOverrides: viewModel.layoutModel.staffClefOverrides)
            let visible = withClefs.filtered(hidingStaves: viewModel.layoutModel.hiddenStaves)
            switch layoutMode {
            case .vertical:
                VerticalScoreContainer(
                    score: visible,
                    staffSize: viewModel.layoutModel.staffSize,
                    honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    playbackCursor: viewModel.playbackCursor,
                    viewModel: viewModel,
                )
            case .horizontal:
                HorizontalScoreContainer(
                    score: visible,
                    staffSize: viewModel.layoutModel.staffSize,
                    honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    playbackCursor: viewModel.playbackCursor,
                    viewModel: viewModel,
                )
            case .page:
                PagedScoreContainer(
                    score: visible,
                    staffSize: viewModel.layoutModel.staffSize,
                    honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    playbackCursor: viewModel.playbackCursor,
                    viewModel: viewModel,
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
/// Documents the shape of a real Score fixture. Not used by the previews below — building a `ReaderRootScreen` preview
/// requires wiring a fake gateway that returns a real `Score`, which is too brittle for a preview. See
/// `PlaybackInspectorScreen` for a productive Score-shaped preview.
@MainActor
private func previewScore() -> Score {
    Score(
        division: 480,
        parts: [],
        metaTags: ["workTitle": "Sample"],
    )
}

#Preview("Loading") {
    ProgressView().controlSize(.large)
}

#Preview("Loaded · vertical · iPhone") {
    // A real assembled-ReaderRootScreen preview would need a fake gateway returning a non-empty Score plus persistence
    // wiring. Snapshot the chrome-only intent here; productive Score shape lives in `PlaybackInspectorScreen`'s
    // preview.
    Text("Run via xcode preview to see the assembled view")
}
#endif
