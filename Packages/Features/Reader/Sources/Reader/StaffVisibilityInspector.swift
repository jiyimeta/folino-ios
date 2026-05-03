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
                hiddenStaffIDs: viewModel.preferences.hiddenStaffIDs,
                onToggle: { await viewModel.toggleStaff(id: $0) },
                onShowAll: { await viewModel.showAllStaves() },
                onHideAll: { await viewModel.hideAllStaves(allStaffIDs: $0) }
            )
        }
        .navigationTitle("Reader")
        #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { viewModel.isInspectorPresented = false }
                }
            }
        #endif
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
                    staffDeclarations: [.previewPlaceholder(forStaffID: 0)]
                ),
            ],
            staves: [StaffContent(id: 0, measures: [])],
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
