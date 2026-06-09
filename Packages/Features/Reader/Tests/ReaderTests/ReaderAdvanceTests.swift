import Domain
import Foundation
@testable import Reader
import Testing

@MainActor
@Suite("ReaderViewModel playlist advance", .serialized)
struct ReaderAdvanceTests {
    private let defaults = UserDefaults.standard

    /// Clears the playlist-continuation key so each test starts from the default `.playThrough` and
    /// leaves no residue in global `UserDefaults` for sibling tests.
    private func resetContinuation() {
        defaults.removeObject(forKey: ReaderGlobalSettingsKey.playlistContinuationMode)
    }

    /// Two distinct score items + a playlist linking them, all live, on a mutable fake repository.
    private func makeRepo() -> (PreviewFakeRepository, ScoreItem, ScoreItem, Playlist) {
        let a = ScoreItem(
            title: "A", composer: "", instrumentationSummary: "", localFileName: "a.mscx",
            contentHash: "a", sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        let b = ScoreItem(
            title: "B", composer: "", instrumentationSummary: "", localFileName: "b.mscx",
            contentHash: "b", sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 2), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        let playlist = Playlist(
            name: "PL", orderedScoreItemIDs: [a.id, b.id], createdAt: Date(timeIntervalSince1970: 0),
        )
        let repo = PreviewFakeRepository()
        repo.scoreItems = [a, b]
        repo.playlists = [playlist]
        return (repo, a, b, playlist)
    }

    private func makeVM(repo: PreviewFakeRepository, item: ScoreItem, playlistID: PlaylistID?) -> ReaderViewModel {
        ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: PreviewFakeGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playlistID: playlistID,
        )
    }

    @Test
    func `advance(to:) retargets the view model to the new score`() async {
        let (repo, a, b, pl) = makeRepo()
        let vm = makeVM(repo: repo, item: a, playlistID: pl.id)
        await vm.load()
        #expect(vm.scoreItem.id == a.id)
        await vm.advance(to: b, autoPlay: false)
        #expect(vm.scoreItem.id == b.id)
    }

    private func setContinuation(_ mode: PlaylistContinuationMode) {
        defaults.set(mode.rawValue, forKey: ReaderGlobalSettingsKey.playlistContinuationMode)
    }

    @Test
    func `reaching end with playThrough advances A -> B`() async {
        let (repo, a, b, pl) = makeRepo()
        resetContinuation()
        setContinuation(.playThrough)
        let vm = makeVM(repo: repo, item: a, playlistID: pl.id)
        await vm.load()
        await vm.handlePlaybackReachedEnd()
        #expect(vm.scoreItem.id == b.id)
    }

    @Test
    func `reaching end at the last score with playThrough stays put`() async {
        let (repo, _, b, pl) = makeRepo()
        resetContinuation()
        setContinuation(.playThrough)
        let vm = makeVM(repo: repo, item: b, playlistID: pl.id)
        await vm.load()
        await vm.handlePlaybackReachedEnd()
        #expect(vm.scoreItem.id == b.id)
    }

    @Test
    func `standalone (no playlistID) never advances`() async {
        let (repo, a, _, _) = makeRepo()
        resetContinuation()
        setContinuation(.playThrough)
        let vm = makeVM(repo: repo, item: a, playlistID: nil)
        await vm.load()
        await vm.handlePlaybackReachedEnd()
        #expect(vm.scoreItem.id == a.id)
        #expect(vm.isInPlaylist == false)
    }

    @Test
    func `active repeat blocks advance even with continuation on`() async {
        let (repo, a, _, pl) = makeRepo()
        resetContinuation()
        setContinuation(.playThrough)
        let vm = makeVM(repo: repo, item: a, playlistID: pl.id)
        await vm.load()
        vm.repeatModel.mode = .loopAll
        await vm.handlePlaybackReachedEnd()
        #expect(vm.scoreItem.id == a.id)
    }
}
