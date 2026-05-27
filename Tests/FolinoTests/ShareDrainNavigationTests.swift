import Domain
@testable import folino
import Foundation
import ImportExport
import Library
import Testing

@Suite("ShareDrainNavigation")
struct ShareDrainNavigationTests {
    private func makeItem(id: ScoreItemID = ScoreItemID()) -> ScoreItem {
        ScoreItem(
            id: id,
            title: "Imported",
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

    private func result(
        imported: [ScoreItemID],
        openAfter: ScoreItem?,
        targetPlaylistID: PlaylistID? = nil,
    ) -> DrainResult {
        DrainResult(
            imported: imported,
            skipped: [],
            openAfter: openAfter,
            createdPlaylistID: nil,
            targetPlaylistID: targetPlaylistID,
            targetPlaylistName: nil,
        )
    }

    /// Regression guard: a single share-extension import with `openAfter` must route to the Reader using the item
    /// carried by `DrainResult`. The old code looked the item up in the asynchronously-observed
    /// `repository.scoreItems` snapshot, which had not yet refreshed at navigation time — so the lookup returned nil
    /// and nothing opened. The decision must depend only on the `DrainResult`, never on a repository snapshot.
    @Test func `single import opens reader with the imported item`() {
        let item = makeItem()
        let nav = ShareDrainNavigation.decide(
            for: result(imported: [item.id], openAfter: item),
            openAfter: true,
        )
        #expect(nav == .openReader(item: item, playlistUnderneath: nil))
    }

    @Test func `single import into playlist pushes that playlist underneath the reader`() {
        let item = makeItem()
        let playlistID = PlaylistID()
        let nav = ShareDrainNavigation.decide(
            for: result(imported: [item.id], openAfter: item, targetPlaylistID: playlistID),
            openAfter: true,
        )
        #expect(nav == .openReader(item: item, playlistUnderneath: .playlistDetail(playlistID)))
    }

    @Test func `multi file import opens the destination playlist list, not the reader`() {
        let a = ScoreItemID()
        let b = ScoreItemID()
        let playlistID = PlaylistID()
        let nav = ShareDrainNavigation.decide(
            for: result(imported: [a, b], openAfter: makeItem(id: b), targetPlaylistID: playlistID),
            openAfter: true,
        )
        #expect(nav == .openList(.playlistDetail(playlistID)))
    }

    @Test func `multi file import without a target playlist falls back to all scores`() {
        let a = ScoreItemID()
        let b = ScoreItemID()
        let nav = ShareDrainNavigation.decide(
            for: result(imported: [a, b], openAfter: makeItem(id: b)),
            openAfter: true,
        )
        #expect(nav == .openList(.allScores))
    }

    @Test func `openAfter false never navigates`() {
        let item = makeItem()
        let nav = ShareDrainNavigation.decide(
            for: result(imported: [item.id], openAfter: item),
            openAfter: false,
        )
        #expect(nav == .none)
    }

    @Test func `nothing actionable stays put`() {
        let nav = ShareDrainNavigation.decide(for: .empty, openAfter: true)
        #expect(nav == .none)
    }
}
