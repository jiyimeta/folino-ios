import Domain
import SheetMusicUI
import SwiftUI

@MainActor
public struct ReaderView: View {
    @State private var viewModel: ReaderViewModel

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL
    ) {
        _viewModel = State(
            wrappedValue: ReaderViewModel(
                scoreItem: scoreItem,
                repository: repository,
                gateway: gateway,
                scoresDirectory: scoresDirectory
            )
        )
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading:
                ProgressView()
                    .controlSize(.large)
            case let .loaded(score):
                ScrollView(.vertical) {
                    ScoreView(score: score)
                        .padding()
                }
            case let .failed(message):
                ContentUnavailableView {
                    Label("Could not open this score", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(viewModel.scoreItem.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .task { await viewModel.load() }
    }
}
