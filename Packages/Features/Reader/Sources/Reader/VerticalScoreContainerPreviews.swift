#if DEBUG
    import Domain
    import SheetMusicCore
    import SwiftUI

    /// Verifies the initial scroll position lands at the *top* of the score —
    /// used to confirm the `.defaultScrollAnchor(.topLeading)` fix in
    /// `VerticalScoreContainer`. Without the modifier this preview opens
    /// around the middle of the score because the container's content grows
    /// from `Color.clear` (size 0×0 while `document == nil`) to the
    /// laid-out page once `rebuildLayout` finishes, and SwiftUI's default
    /// 2-axis scroll anchor preserves the *centre* across content-size
    /// changes.
    #Preview("Initial scroll · top of score") {
        let score = PreviewSampleScore.tall
        let repo = PreviewFakeRepository()
        let vm = ReaderViewModel(
            scoreItem: PreviewFakeRepository.sampleItem,
            repository: repo,
            gateway: PreviewFakeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp")
        )
        VerticalScoreContainer(
            score: score,
            staffSize: 14,
            honorLayoutBreaks: false,
            playbackCursor: nil,
            viewModel: vm
        )
        .frame(width: 600, height: 500)
    }
#endif
