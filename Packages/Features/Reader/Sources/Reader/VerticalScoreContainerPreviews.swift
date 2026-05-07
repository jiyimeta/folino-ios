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

    // MARK: - A–B loop boundary marker previews

    /// Fake repository that returns a pre-seeded `ReaderPreferences` so the
    /// A–B marker previews can show the markers without requiring a playback
    /// cursor or any async mutations beyond `vm.load()`.
    @MainActor
    @Observable
    private final class PreviewABRepository: ScoreLibraryRepository {
        var scoreItems: [ScoreItem] = []
        var tags: [Tag] = []
        var playlists: [Playlist] = []
        let seededPreferences: ReaderPreferences

        init(preferences: ReaderPreferences) {
            seededPreferences = preferences
        }

        func refresh() throws {}
        func saveScoreItem(_: ScoreItem) throws {}
        func deleteScoreItem(id _: Domain.ScoreItemID) throws {}
        func saveTag(_: Tag) throws {}
        func deleteTag(id _: TagID) throws {}
        func savePlaylist(_: Playlist) throws {}
        func deletePlaylist(id _: PlaylistID) throws {}
        func scoreItems(matchingContentHash _: String) throws -> [ScoreItem] { [] }
        func loadReaderPreferences(for _: Domain.ScoreItemID) throws -> ReaderPreferences? {
            seededPreferences
        }

        func saveReaderPreferences(_: ReaderPreferences) throws {}
    }

    #Preview("A–B markers · multi-bar") {
        let score = PreviewSampleScore.tall
        let item = PreviewFakeRepository.sampleItem
        // Pre-seed an A–B loop spanning a few bars. ChordPath only needs
        // the indices the overlay reads — markers gate on measureIndex,
        // so chordIndex/voiceIndex/systemIndex can stay at 0.
        let prefs = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            repeatMode: .abLoop,
            abRepeat: ABRepeatRange(
                start: ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0),
                end: ChordPath(systemIndex: 0, measureIndex: 3, voiceIndex: 0, chordIndex: 0)
            )
        )
        let repo = PreviewABRepository(preferences: prefs)
        let vm = ReaderViewModel(
            scoreItem: item,
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
        .task { await vm.load() }
    }

    #Preview("A–B markers · same measure") {
        let score = PreviewSampleScore.tall
        let item = PreviewFakeRepository.sampleItem
        let p = ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
        let prefs = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            repeatMode: .abLoop,
            abRepeat: ABRepeatRange(start: p, end: p)
        )
        let repo = PreviewABRepository(preferences: prefs)
        let vm = ReaderViewModel(
            scoreItem: item,
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
        .task { await vm.load() }
    }
#endif
