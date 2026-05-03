import Domain
import SheetMusicCore
import SheetMusicUI
import SwiftUI

@MainActor
public struct ReaderView: View {
    @State private var viewModel: ReaderViewModel
    @AppStorage(ReaderLayoutMode.appStorageKey) private var rawLayoutMode = ReaderLayoutMode.appStorageDefault
    @State private var pageIndex = 0
    @State private var totalPages = 1
    @Environment(\.horizontalSizeClass) private var _horizontalSizeClass

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL
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
                defaultStaffSize: initialDefault
            )
        )
    }

    private var layoutMode: Binding<ReaderLayoutMode> {
        Binding(
            get: { ReaderLayoutMode(rawValue: rawLayoutMode) ?? .vertical },
            set: { rawLayoutMode = $0.rawValue }
        )
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            content
            ReaderBottomOverlay(
                viewModel: viewModel,
                layoutMode: layoutMode.wrappedValue,
                pageIndex: pageIndex,
                totalPages: totalPages
            )
        }
        .navigationTitle(viewModel.scoreItem.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(viewModel.isChromeVisible ? .visible : .hidden, for: .navigationBar)
            .statusBarHidden(!viewModel.isChromeVisible)
        #endif
            .toolbar {
                ReaderToolbar(viewModel: viewModel, layoutMode: layoutMode)
            }
            .inspector(isPresented: $viewModel.isInspectorPresented) {
                if case let .loaded(score) = viewModel.loadState {
                    StaffVisibilityInspector(viewModel: viewModel, score: score)
                } else {
                    Color.clear
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
            let visible = score.filtered(hidingStaffIDs: viewModel.preferences.hiddenStaffIDs)
            ReaderGestureLayer(
                viewModel: viewModel,
                isPageMode: layoutMode.wrappedValue == .page,
                onPrevPage: { pageIndex = max(0, pageIndex - 1) },
                onNextPage: { pageIndex = max(0, min(totalPages - 1, pageIndex + 1)) }
            ) {
                switch layoutMode.wrappedValue {
                case .vertical:
                    VerticalScoreContainer(
                        score: visible,
                        staffSize: viewModel.preferences.staffSize
                    )
                case .page:
                    PagedScoreView(
                        score: visible,
                        options: ScoreViewOptions(
                            staffSize: viewModel.preferences.staffSize,
                            systemGap: viewModel.preferences.staffSize * 1.25,
                            wrapToViewWidth: true
                        ),
                        pageIndex: $pageIndex,
                        totalPages: $totalPages
                    )
                }
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
