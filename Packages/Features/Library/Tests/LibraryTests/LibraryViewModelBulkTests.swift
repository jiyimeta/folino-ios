import Domain
import Foundation
@testable import Library
import Testing

@MainActor
struct LibraryViewModelBulkTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(title: String) -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private struct VMFixture {
        let vm: LibraryViewModel
        let repo: FakeScoreLibraryRepository
    }

    private static func makeVM(scoreItems: [ScoreItem] = []) -> VMFixture {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = scoreItems
        let vm = LibraryViewModel(
            repository: repo,
            importer: FakeScoreFileImporter(),
            gateway: FakeScoreFileGateway(),
            shareService: FakeScoreShareService(),
        )
        return VMFixture(vm: vm, repo: repo)
    }

    // MARK: - bulkDelete

    @Test func `bulk delete removes all passed I ds`() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let c = Self.makeItem(title: "C")
        let f = Self.makeVM(scoreItems: [a, b, c])

        await f.vm.bulkDelete([a.id, c.id])

        #expect(Set(f.repo.deletedScoreItemIDs) == [a.id, c.id])
        #expect(f.repo.scoreItems.map(\.id) == [b.id])
        #expect(f.vm.errorAlertMessage == nil)
    }

    @Test func `bulk delete empty is no op`() async {
        let f = Self.makeVM(scoreItems: [Self.makeItem(title: "A")])
        await f.vm.bulkDelete([])
        #expect(f.repo.deletedScoreItemIDs.isEmpty)
        #expect(f.vm.errorAlertMessage == nil)
    }

    @Test func `bulk delete stops at first error`() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let f = Self.makeVM(scoreItems: [a, b])
        f.repo.deleteScoreItemError = .persistenceFailed(reason: "boom")

        await f.vm.bulkDelete([a.id, b.id])

        #expect(f.repo.deletedScoreItemIDs.isEmpty) // FakeRepo throws before recording
        #expect(f.vm.errorAlertMessage != nil)
    }

    // MARK: - bulkRestore

    @Test func `bulk restore returns all to live`() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let f = Self.makeVM(scoreItems: [a, b])
        await f.vm.bulkDelete([a.id, b.id])
        #expect(f.repo.deletedScoreItems.count == 2)

        await f.vm.bulkRestore([a.id, b.id])

        #expect(Set(f.repo.restoredScoreItemIDs) == [a.id, b.id])
        #expect(f.repo.deletedScoreItems.isEmpty)
        #expect(f.repo.scoreItems.count == 2)
    }

    // MARK: - bulkPermanentlyDelete

    @Test func `bulk permanently delete removes from both buckets`() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let f = Self.makeVM(scoreItems: [a, b])
        await f.vm.bulkDelete([a.id, b.id])
        #expect(f.repo.deletedScoreItems.count == 2)

        await f.vm.bulkPermanentlyDelete([a.id, b.id])

        #expect(Set(f.repo.permanentlyDeletedScoreItemIDs) == [a.id, b.id])
        #expect(f.repo.scoreItems.isEmpty)
        #expect(f.repo.deletedScoreItems.isEmpty)
    }

    // MARK: - bulkRemoveFromPlaylist

    @Test func `bulk remove from playlist filters and preserves order`() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let c = Self.makeItem(title: "C")
        let f = Self.makeVM(scoreItems: [a, b, c])
        let playlist = Playlist(
            name: "P",
            orderedScoreItemIDs: [a.id, b.id, c.id],
            createdAt: Self.base,
        )
        f.repo.playlists = [playlist]

        await f.vm.bulkRemoveFromPlaylist([a.id, c.id], from: playlist)

        #expect(f.repo.savedPlaylists.last?.orderedScoreItemIDs == [b.id])
        #expect(f.repo.scoreItems.count == 3) // scores stay
    }

    @Test func `bulk remove from playlist empty is no op`() async {
        let a = Self.makeItem(title: "A")
        let f = Self.makeVM(scoreItems: [a])
        let playlist = Playlist(
            name: "P", orderedScoreItemIDs: [a.id], createdAt: Self.base,
        )
        f.repo.playlists = [playlist]

        await f.vm.bulkRemoveFromPlaylist([], from: playlist)

        #expect(f.repo.savedPlaylists.isEmpty)
    }

    // MARK: - bulkAddToPlaylist

    @Test func `bulk add to playlist appends missing preserves order`() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let c = Self.makeItem(title: "C")
        let f = Self.makeVM(scoreItems: [a, b, c])
        let playlist = Playlist(
            name: "P", orderedScoreItemIDs: [a.id], createdAt: Self.base,
        )
        f.repo.playlists = [playlist]

        await f.vm.bulkAddToPlaylist([b.id, a.id, c.id], to: playlist)

        // a already present; b and c appended in caller order, a not duplicated.
        #expect(f.repo.savedPlaylists.last?.orderedScoreItemIDs == [a.id, b.id, c.id])
    }

    @Test func `bulk add to playlist all present is no op`() async {
        let a = Self.makeItem(title: "A")
        let f = Self.makeVM(scoreItems: [a])
        let playlist = Playlist(
            name: "P", orderedScoreItemIDs: [a.id], createdAt: Self.base,
        )
        f.repo.playlists = [playlist]

        await f.vm.bulkAddToPlaylist([a.id], to: playlist)

        #expect(f.repo.savedPlaylists.isEmpty)
    }

    @Test func `bulk add to playlist empty is no op`() async {
        let f = Self.makeVM()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [], createdAt: Self.base)
        f.repo.playlists = [playlist]

        await f.vm.bulkAddToPlaylist([], to: playlist)

        #expect(f.repo.savedPlaylists.isEmpty)
    }

    // MARK: - bulkAddTags

    @Test func `bulk add tags unions tag sets`() async {
        let tagA = TagID()
        let tagB = TagID()
        var item1 = Self.makeItem(title: "1"); item1.tagIDs = [tagA]
        var item2 = Self.makeItem(title: "2"); item2.tagIDs = []
        let f = Self.makeVM(scoreItems: [item1, item2])

        await f.vm.bulkAddTags([item1.id, item2.id], tagIDs: [tagB])

        let saved1 = f.repo.scoreItems.first { $0.id == item1.id }
        let saved2 = f.repo.scoreItems.first { $0.id == item2.id }
        #expect(saved1?.tagIDs == [tagA, tagB])
        #expect(saved2?.tagIDs == [tagB])
    }

    @Test func `bulk add tags skips writes when already has all`() async {
        let tagA = TagID()
        var item = Self.makeItem(title: "1"); item.tagIDs = [tagA]
        let f = Self.makeVM(scoreItems: [item])

        await f.vm.bulkAddTags([item.id], tagIDs: [tagA])

        #expect(f.repo.savedScoreItems.isEmpty)
    }

    @Test func `bulk add tags empty tags is no op`() async {
        let item = Self.makeItem(title: "1")
        let f = Self.makeVM(scoreItems: [item])

        await f.vm.bulkAddTags([item.id], tagIDs: [])

        #expect(f.repo.savedScoreItems.isEmpty)
    }
}
