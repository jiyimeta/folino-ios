@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@MainActor
struct LiveScoreLibraryRepositoryTests {
    /// Returns a database AND a lifetime anchor that keeps the temp directory alive for the duration of the test. Both
    /// must be retained together.
    private func makeDatabase() throws -> (AppDatabase, TempDirectory) {
        let tmp = try TempDirectory()
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        return (db, tmp)
    }

    @Test func `refresh on empty database produces empty arrays`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()
        #expect(repo.scoreItems.isEmpty)
        #expect(repo.tags.isEmpty)
        #expect(repo.playlists.isEmpty)
    }

    @Test func `save score item round trips via observation`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let tag = Domain.Tag(name: "Bach", colorHex: "#FF0000")
        try await db.pool.write { try TagRecord(domain: tag).insert($0) }

        let item = ScoreItem(
            title: "Prelude", composer: "Bach", instrumentationSummary: "Piano",
            localFileName: "x.mscz", contentHash: "h1", sizeBytes: 100,
            lengthBeats: 16, defaultTempoBpm: 80, primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [tag.id], isFavorite: false,
        )
        try await repo.saveScoreItem(item)

        try await waitFor { repo.scoreItems.contains { $0.id == item.id } }
        let stored = try #require(repo.scoreItems.first { $0.id == item.id })
        #expect(stored.tagIDs == [tag.id])
        #expect(stored.title == "Prelude")
    }

    @Test func `saving and reading back preserves credit fields`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        var item = makeBareItem(localFileName: "credits.mid", contentHash: "credits")
        item.arranger = "A"
        item.lyricist = "L"
        item.copyright = "©"
        try await repo.saveScoreItem(item)

        try await waitFor { repo.scoreItems.contains { $0.id == item.id } }
        let stored = try #require(repo.scoreItems.first { $0.id == item.id })
        #expect(stored.arranger == "A")
        #expect(stored.lyricist == "L")
        #expect(stored.copyright == "©")
    }

    @Test func `delete score item soft deletes and moves to trash`() async throws {
        let (db, lifetime) = try makeDatabase()
        let scoresDir = try TempDirectory()
        defer { withExtendedLifetime((lifetime, scoresDir)) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir.url)
        try await repo.refresh()

        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.saveScoreItem(item)
        try await waitFor { repo.scoreItems.contains { $0.id == item.id } }

        try await repo.deleteScoreItem(id: item.id)
        try await waitFor { !repo.scoreItems.contains { $0.id == item.id } }
        try await waitFor { repo.deletedScoreItems.contains { $0.id == item.id } }
        let trashed = try #require(repo.deletedScoreItems.first { $0.id == item.id })
        #expect(trashed.deletedAt != nil)
    }

    @Test func `soft delete keeps file on disk`() async throws {
        let (db, lifetime) = try makeDatabase()
        let scoresDir = try TempDirectory()
        defer { withExtendedLifetime((lifetime, scoresDir)) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir.url)
        try await repo.refresh()

        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.saveScoreItem(item)
        let fileURL = scoresDir.url.appending(path: item.localFileName)
        try Data("dummy".utf8).write(to: fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try await repo.softDeleteScoreItem(id: item.id)
        try await waitFor { repo.deletedScoreItems.contains { $0.id == item.id } }
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func `restore returns item to live snapshot`() async throws {
        let (db, lifetime) = try makeDatabase()
        let scoresDir = try TempDirectory()
        defer { withExtendedLifetime((lifetime, scoresDir)) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir.url)
        try await repo.refresh()

        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.saveScoreItem(item)
        try await repo.softDeleteScoreItem(id: item.id)
        try await waitFor { repo.deletedScoreItems.contains { $0.id == item.id } }

        try await repo.restoreScoreItem(id: item.id)
        try await waitFor { repo.scoreItems.contains { $0.id == item.id } }
        #expect(!repo.deletedScoreItems.contains { $0.id == item.id })
        let restored = try #require(repo.scoreItems.first { $0.id == item.id })
        #expect(restored.deletedAt == nil)
    }

    @Test func `permanently delete removes row and file`() async throws {
        let (db, lifetime) = try makeDatabase()
        let scoresDir = try TempDirectory()
        defer { withExtendedLifetime((lifetime, scoresDir)) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir.url)
        try await repo.refresh()

        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.saveScoreItem(item)
        let fileURL = scoresDir.url.appending(path: item.localFileName)
        try Data("dummy".utf8).write(to: fileURL)
        try await repo.softDeleteScoreItem(id: item.id)
        try await waitFor { repo.deletedScoreItems.contains { $0.id == item.id } }

        try await repo.permanentlyDeleteScoreItem(id: item.id)
        try await waitFor { !repo.deletedScoreItems.contains { $0.id == item.id } }
        #expect(!repo.scoreItems.contains { $0.id == item.id })
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func `prune removes only items past cutoff`() async throws {
        let (db, lifetime) = try makeDatabase()
        let scoresDir = try TempDirectory()
        defer { withExtendedLifetime((lifetime, scoresDir)) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir.url)
        try await repo.refresh()

        let now = Date()
        let stale = makeBareItem(localFileName: "stale.mid", contentHash: "s")
        let fresh = makeBareItem(localFileName: "fresh.mid", contentHash: "f")
        try await repo.saveScoreItem(stale)
        try await repo.saveScoreItem(fresh)
        // Stamp deleted_at directly so we can choose absolute times.
        try await db.pool.write { db in
            try db.execute(
                sql: "UPDATE score_items SET deleted_at = ? WHERE id = ?",
                arguments: [
                    now.addingTimeInterval(-60 * 86400).timeIntervalSince1970,
                    stale.id.rawValue.uuidString,
                ],
            )
            try db.execute(
                sql: "UPDATE score_items SET deleted_at = ? WHERE id = ?",
                arguments: [
                    now.addingTimeInterval(-1 * 86400).timeIntervalSince1970,
                    fresh.id.rawValue.uuidString,
                ],
            )
        }
        try await waitFor { repo.deletedScoreItems.count == 2 }

        try await repo.pruneScoreItemsDeleted(before: now.addingTimeInterval(-30 * 86400))

        try await waitFor { repo.deletedScoreItems.count == 1 }
        #expect(repo.deletedScoreItems.first?.id == fresh.id)
    }

    @Test func `soft deleted items excluded from content hash lookup`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let hash = "dup-hash"
        let live = makeBareItem(localFileName: "live.mid", contentHash: hash)
        let trashed = makeBareItem(localFileName: "trashed.mid", contentHash: hash)
        try await repo.saveScoreItem(live)
        try await repo.saveScoreItem(trashed)
        try await repo.softDeleteScoreItem(id: trashed.id)
        try await waitFor { repo.deletedScoreItems.contains { $0.id == trashed.id } }

        let matches = try await repo.scoreItems(matchingContentHash: hash)
        #expect(matches.count == 1)
        #expect(matches.first?.id == live.id)
    }

    @Test func `PDF-origin fields round trip through the database`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        var item = makeBareItem(localFileName: "converted.mscz", contentHash: "mscz-hash")
        item.sourcePDFFileName = "converted.pdf"
        item.sourcePDFContentHash = "pdf-hash"
        item.pdfDerivedContentHash = "mscz-hash"
        try await repo.saveScoreItem(item)

        try await waitFor { repo.scoreItems.contains { $0.id == item.id } }
        let stored = try #require(repo.scoreItems.first { $0.id == item.id })
        #expect(stored.sourcePDFFileName == "converted.pdf")
        #expect(stored.sourcePDFContentHash == "pdf-hash")
        #expect(stored.pdfDerivedContentHash == "mscz-hash")
        #expect(!stored.pdfConversionFailed)
        #expect(stored.pdfOriginState == .converted)
    }

    @Test func `re-importing the same PDF is a duplicate even after conversion`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        var item = makeBareItem(localFileName: "converted.mscz", contentHash: "mscz-hash")
        item.sourcePDFFileName = "converted.pdf"
        item.sourcePDFContentHash = "pdf-hash"
        item.pdfDerivedContentHash = "mscz-hash"
        try await repo.saveScoreItem(item)

        let matches = try await repo.scoreItems(matchingContentHash: "pdf-hash")
        #expect(matches.map(\.id) == [item.id])
    }

    @Test func `permanently deleting a converted item takes its original PDF with it`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let scores = try TempDirectory()
        defer { withExtendedLifetime(scores) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scores.url)
        try await repo.refresh()

        var item = makeBareItem(localFileName: "converted.mscz", contentHash: "mscz-hash")
        item.sourcePDFFileName = "converted.pdf"
        item.sourcePDFContentHash = "pdf-hash"
        item.pdfDerivedContentHash = "mscz-hash"
        try await repo.saveScoreItem(item)
        try Data("score".utf8).write(to: scores.url.appending(path: "converted.mscz"))
        try Data("pdf".utf8).write(to: scores.url.appending(path: "converted.pdf"))

        try await repo.permanentlyDeleteScoreItem(id: item.id)

        #expect(!FileManager.default.fileExists(atPath: scores.url.appending(path: "converted.mscz").path))
        #expect(!FileManager.default.fileExists(atPath: scores.url.appending(path: "converted.pdf").path))
    }

    private func makeBareItem(localFileName: String, contentHash: String) -> ScoreItem {
        ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: localFileName, contentHash: contentHash, sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    @Test func `save tag appears in observed array`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let tag = Domain.Tag(name: "Romantic", colorHex: "#00FFAA")
        try await repo.saveTag(tag)
        try await waitFor { repo.tags.contains { $0.id == tag.id } }
    }

    @Test func `delete tag cascades to item tag I ds`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let tag = Domain.Tag(name: "x", colorHex: "#000000")
        try await repo.saveTag(tag)
        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [tag.id], isFavorite: false,
        )
        try await repo.saveScoreItem(item)
        try await waitFor { repo.scoreItems.first { $0.id == item.id }?.tagIDs == [tag.id] }

        try await repo.deleteTag(id: tag.id)
        try await waitFor { repo.scoreItems.first { $0.id == item.id }?.tagIDs.isEmpty == true }
    }

    @Test func `content hash lookup returns all matches`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let h = "shared-hash"
        func make() -> ScoreItem {
            ScoreItem(
                title: "x", composer: nil, instrumentationSummary: nil,
                localFileName: "\(UUID().uuidString).mid", contentHash: h, sizeBytes: 0,
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
                addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
            )
        }
        try await repo.saveScoreItem(make())
        try await repo.saveScoreItem(make())
        let unique = make()
        let renamed = ScoreItem(
            id: unique.id, title: unique.title, composer: nil,
            instrumentationSummary: nil, localFileName: unique.localFileName,
            contentHash: "different", sizeBytes: 0, lengthBeats: 0,
            defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.saveScoreItem(renamed)

        let dups = try await repo.scoreItems(matchingContentHash: h)
        #expect(dups.count == 2)
    }

    @Test func `playlist ordering round trips through observation`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        func make() -> ScoreItem {
            ScoreItem(
                title: "x", composer: nil, instrumentationSummary: nil,
                localFileName: "\(UUID().uuidString).mid", contentHash: "h", sizeBytes: 0,
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
                addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
            )
        }
        let a = make(); let b = make(); let c = make()
        try await repo.saveScoreItem(a)
        try await repo.saveScoreItem(b)
        try await repo.saveScoreItem(c)
        try await waitFor { repo.scoreItems.count == 3 }

        let pl = Playlist(
            name: "Practice",
            orderedScoreItemIDs: [c.id, a.id, b.id],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        try await repo.savePlaylist(pl)
        try await waitFor {
            repo.playlists.first?.orderedScoreItemIDs == [c.id, a.id, b.id]
        }
        #expect(repo.playlists.count == 1)
    }

    @Test func `delete playlist removes it`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let pl = Playlist(name: "x", orderedScoreItemIDs: [], createdAt: Date())
        try await repo.savePlaylist(pl)
        try await waitFor { repo.playlists.contains { $0.id == pl.id } }
        try await repo.deletePlaylist(id: pl.id)
        try await waitFor { !repo.playlists.contains { $0.id == pl.id } }
    }

    // MARK: - Reader preferences

    @Test func `load reader preferences returns nil when absent`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        let result = try await repo.loadReaderPreferences(for: ScoreItemID())
        #expect(result == nil)
    }

    @Test func `save then load round trips reader preferences`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        let item = ScoreItem(
            title: "Prelude", composer: "Bach", instrumentationSummary: "Piano",
            localFileName: "x.mscz", contentHash: "h1", sizeBytes: 100,
            lengthBeats: 16, defaultTempoBpm: 80, primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.refresh()
        try await repo.saveScoreItem(item)

        let hidden: Set<StaffAddress> = [
            StaffAddress(partIndex: 0, staffIndexInPart: 1),
            StaffAddress(partIndex: 2, staffIndexInPart: 0),
        ]
        let prefs = ReaderPreferences(
            scoreItemID: item.id, staffSize: 18, hiddenStaves: hidden,
        )
        try await repo.saveReaderPreferences(prefs)

        let loaded = try await repo.loadReaderPreferences(for: item.id)
        #expect(loaded?.staffSize == 18)
        #expect(loaded?.hiddenStaves == hidden)
        #expect(loaded?.scoreItemID == item.id)
    }

    @Test func `save reader preferences upserts existing`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        let item = ScoreItem(
            title: "Prelude", composer: "Bach", instrumentationSummary: "Piano",
            localFileName: "x.mscz", contentHash: "h1", sizeBytes: 100,
            lengthBeats: 16, defaultTempoBpm: 80, primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.refresh()
        try await repo.saveScoreItem(item)

        let first = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaves: [],
        )
        try await repo.saveReaderPreferences(first)

        var second = first
        second.staffSize = 20
        second.hiddenStaves = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
        try await repo.saveReaderPreferences(second)

        let loaded = try await repo.loadReaderPreferences(for: item.id)
        #expect(loaded?.staffSize == 20)
        #expect(loaded?.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 0)])
    }
}
