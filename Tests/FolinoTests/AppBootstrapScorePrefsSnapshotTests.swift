import Domain
@testable import folino
import Foundation
import Observation
import Testing

/// Covers the App-owned half of the launch `score_prefs` snapshot. Parameter selection and bucketing belong to the
/// Domain factory (and are tested there); what this layer decides is which rows reach it — the live-item filter comes
/// from `scoreItems`, and a failed read degrades to zero events instead of failing the launch snapshot.
@MainActor
@Suite("AppBootstrap score_prefs snapshot")
struct AppBootstrapScorePrefsSnapshotTests {
    @Test func `a touched live score produces one event carrying the measured width`() async {
        let live = makeItem()
        let repository = StubScoreLibraryRepository()
        repository.scoreItems = [live]
        repository.preferences = [touched(live.id, staffSize: 18)]

        let events = await AppBootstrap.scorePrefsEvents(repository: repository, screenWidthPt: 700)

        #expect(events.count == 1)
        #expect(events[0].name == "score_prefs")
        #expect(events[0].parameters["staff_size"] == .int(18))
        #expect(events[0].parameters["screen_width_pt"] == .int(430))
    }

    /// The filter is taken from `scoreItems`, which excludes soft-deleted rows — so a trashed score's preferences never
    /// reach the factory and the event count stays comparable with `library_snapshot.score_count_total`.
    @Test func `a trashed score contributes no event`() async {
        let live = makeItem()
        let trashed = makeItem()
        let repository = StubScoreLibraryRepository()
        repository.scoreItems = [live]
        repository.deletedScoreItems = [trashed]
        repository.preferences = [touched(live.id, staffSize: 18), touched(trashed.id, staffSize: 24)]

        let events = await AppBootstrap.scorePrefsEvents(repository: repository, screenWidthPt: 430)

        #expect(events.count == 1)
        #expect(events[0].parameters["staff_size"] == .int(18))
    }

    @Test func `an all-untouched library emits nothing`() async {
        let live = makeItem()
        let repository = StubScoreLibraryRepository()
        repository.scoreItems = [live]
        repository.preferences = [ReaderPreferences(scoreItemID: live.id, hiddenStaves: [])]

        let events = await AppBootstrap.scorePrefsEvents(repository: repository, screenWidthPt: 430)

        #expect(events.isEmpty)
    }

    @Test func `a failed preferences read degrades to no events`() async {
        let live = makeItem()
        let repository = StubScoreLibraryRepository()
        repository.scoreItems = [live]
        repository.preferences = [touched(live.id, staffSize: 18)]
        repository.readFailure = StubScoreLibraryRepository.ReadFailure()

        let events = await AppBootstrap.scorePrefsEvents(repository: repository, screenWidthPt: 430)

        #expect(events.isEmpty)
    }

    // MARK: - Helpers

    private func touched(_ id: ScoreItemID, staffSize: Double) -> ReaderPreferences {
        ReaderPreferences(scoreItemID: id, staffSize: staffSize, hiddenStaves: [])
    }

    private func makeItem(id: ScoreItemID = ScoreItemID()) -> ScoreItem {
        ScoreItem(
            id: id,
            title: "Score",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "\(id.rawValue.uuidString).mscz",
            contentHash: "hash",
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: .now,
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }
}

@MainActor
@Observable
private final class StubScoreLibraryRepository: ScoreLibraryRepository {
    struct ReadFailure: Error {}

    var scoreItems: [ScoreItem] = []
    var deletedScoreItems: [ScoreItem] = []
    // Fully qualified: Swift Testing also exports a `Tag`.
    var tags: [Domain.Tag] = []
    var playlists: [Playlist] = []

    var preferences: [ReaderPreferences] = []
    var readFailure: (any Error)?

    func refresh() throws {}
    func saveScoreItem(_ item: ScoreItem) throws {}
    func deleteScoreItem(id: ScoreItemID) throws {}
    func softDeleteScoreItem(id: ScoreItemID) throws {}
    func restoreScoreItem(id: ScoreItemID) throws {}
    func permanentlyDeleteScoreItem(id: ScoreItemID) throws {}
    func pruneScoreItemsDeleted(before cutoff: Date) throws {}
    func saveTag(_ tag: Domain.Tag) throws {}
    func deleteTag(id: TagID) throws {}
    func savePlaylist(_ playlist: Playlist) throws {}
    func deletePlaylist(id: PlaylistID) throws {}
    func scoreItems(matchingContentHash contentHash: String) throws -> [ScoreItem] {
        []
    }

    func loadReaderPreferences(for scoreItemID: ScoreItemID) throws -> ReaderPreferences? {
        preferences.first { $0.scoreItemID == scoreItemID }
    }

    func saveReaderPreferences(_ preferences: ReaderPreferences) throws {}

    func allReaderPreferences() throws -> [ReaderPreferences] {
        if let readFailure { throw readFailure }
        return preferences
    }
}
