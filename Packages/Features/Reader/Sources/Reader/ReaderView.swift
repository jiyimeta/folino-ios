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
            case .failed:
                // Real implementation lands in Task 21.
                ProgressView()
                    .controlSize(.large)
            }
        }
        .navigationTitle(viewModel.scoreItem.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .task { await viewModel.load() }
    }
}
