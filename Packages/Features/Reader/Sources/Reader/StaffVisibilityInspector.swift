import SheetMusicCore
import SwiftUI

/// Top-level content for the Reader inspector pane. Currently hosts only
/// `StaffVisibilitySection`; Plan B inserts a Mixer section below.
struct StaffVisibilityInspector: View {
    @Bindable var viewModel: ReaderViewModel
    let score: Score

    var body: some View {
        Form {
            StaffVisibilitySection(
                score: score,
                hiddenStaves: viewModel.preferences.hiddenStaves,
                onToggle: { await viewModel.toggleStaff(address: $0) }
            )
        }
        .navigationTitle("Reader")
    }
}

#if DEBUG
    #Preview {
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Violin",
                    instrument: .previewEmpty,
                    staves: [Staff(staffType: "stdNormal", group: "pitched")]
                ),
            ],
            metaTags: [:]
        )
        let repo = PreviewFakeRepository()
        let vm = ReaderViewModel(
            scoreItem: PreviewFakeRepository.sampleItem,
            repository: repo,
            gateway: PreviewFakeGateway(),
            scoresDirectory: URL(filePath: "/tmp")
        )
        return StaffVisibilityInspector(viewModel: vm, score: score)
    }
#endif
