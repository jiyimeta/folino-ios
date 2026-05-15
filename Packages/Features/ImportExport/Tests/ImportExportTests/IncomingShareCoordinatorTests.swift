import Domain
import Foundation
@testable import ImportExport
import ImportExportAppGroup
import Testing
import UtilityCore

@MainActor
@Suite("IncomingShareCoordinator")
struct IncomingShareCoordinatorTests {
    // MARK: - Test fixtures

    final class FakeImporter: ScoreFileImporter, @unchecked Sendable {
        var prepared: [URL] = []
        var committed: [(ImportPlan, ImportDecision)] = []
        var duplicateMap: [String: ScoreItem] = [:]
        var prepareError: (any Error)?
        var commitError: (any Error)?

        func prepareImport(sourceURL: URL) throws -> ImportPlan {
            if let prepareError { throw prepareError }
            prepared.append(sourceURL)
            let filename = sourceURL.lastPathComponent
            let duplicate = duplicateMap[filename]
            return ImportPlan(
                sourceURL: sourceURL,
                stagedURL: sourceURL,
                format: .mscz,
                summary: ScoreFileSummary(
                    title: filename,
                    composer: nil,
                    instrumentationSummary: "",
                    lengthBeats: 1,
                    defaultTempoBpm: 120,
                    primaryKey: nil,
                ),
                contentHash: filename,
                sizeBytes: 1,
                duplicates: duplicate.map { [$0] } ?? [],
            )
        }

        func commitImport(_ plan: ImportPlan, decision: ImportDecision) throws -> ScoreItem {
            if let commitError { throw commitError }
            committed.append((plan, decision))
            if case let .openExisting(id) = decision,
               let existing = duplicateMap[plan.sourceURL.lastPathComponent],
               existing.id == id
            {
                return existing
            }
            let id = ScoreItemID()
            return ScoreItem(
                id: id,
                title: plan.summary.title ?? plan.sourceURL.lastPathComponent,
                composer: nil,
                instrumentationSummary: nil,
                localFileName: "\(id).mscz",
                contentHash: plan.contentHash,
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
    final class FakeRepository: ScoreLibraryRepository {
        var scoreItems: [ScoreItem] = []
        var tags: [Domain.Tag] = []
        var playlists: [Playlist] = []
        var savedPlaylists: [Playlist] = []
        var savedScoreItems: [ScoreItem] = []
        var prefs: [ScoreItemID: ReaderPreferences] = [:]

        func refresh() throws {}
        func saveScoreItem(_ item: ScoreItem) throws {
            savedScoreItems.append(item)
            scoreItems.append(item)
        }

        func deleteScoreItem(id: ScoreItemID) throws {
            scoreItems.removeAll { $0.id == id }
        }

        func saveTag(_ tag: Domain.Tag) throws {}
        func deleteTag(id: TagID) throws {}
        func savePlaylist(_ playlist: Playlist) throws {
            savedPlaylists.append(playlist)
            if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[idx] = playlist
            } else {
                playlists.append(playlist)
            }
        }

        func deletePlaylist(id: PlaylistID) throws {
            playlists.removeAll { $0.id == id }
        }

        func scoreItems(matchingContentHash contentHash: String) throws -> [ScoreItem] {
            scoreItems.filter { $0.contentHash == contentHash }
        }

        func loadReaderPreferences(for scoreItemID: ScoreItemID) throws -> ReaderPreferences? {
            prefs[scoreItemID]
        }

        func saveReaderPreferences(_ preferences: ReaderPreferences) throws {
            prefs[preferences.scoreItemID] = preferences
        }
    }

    struct FixedClock: Clock {
        let date: Date
        func now() -> Date {
            date
        }
    }

    // MARK: - Helpers

    func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "share-coord-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func stageToken(
        _ container: URL,
        token: UUID,
        playlistID: PlaylistID? = nil,
        newPlaylistName: String? = nil,
        openAfter: Bool = false,
        filenames: [String],
        createdAt: Date = .now,
    ) throws {
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: container)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        var files: [IncomingShareIntent.File] = []
        for name in filenames {
            let dest = filesURL.appending(path: name, directoryHint: .notDirectory)
            try Data("dummy".utf8).write(to: dest)
            files.append(.init(relativePath: "files/\(name)", originalName: name))
        }
        let intent = IncomingShareIntent(
            schemaVersion: 1,
            token: token,
            createdAt: createdAt,
            playlistID: playlistID,
            newPlaylistName: newPlaylistName,
            openAfter: openAfter,
            files: files,
        )
        let data = try JSONEncoder().encode(intent)
        try data.write(to: AppGroupPaths.tokenIntentURL(token: token, in: container))
    }

    // MARK: - Tests

    @Test func `librar only single file`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let repo = FakeRepository()
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let token = UUID()
        try stageToken(container, token: token, filenames: ["one.mscz"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.count == 1)
        #expect(result.skipped.isEmpty)
        #expect(result.targetPlaylistID == nil)
        #expect(result.createdPlaylistID == nil)
        #expect(result.openAfter == nil)
        #expect(repo.savedPlaylists.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: AppGroupPaths.tokenURL(token: token, in: container).path))
    }

    @Test func `multiple files appended to existing playlist`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let repo = FakeRepository()
        let existing = Playlist(name: "Practice", orderedScoreItemIDs: [], createdAt: .now)
        repo.playlists = [existing]
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let token = UUID()
        try stageToken(
            container,
            token: token,
            playlistID: existing.id,
            openAfter: true,
            filenames: ["a.mscz", "b.mscz"],
        )

        let result = await coordinator.drain(token: token)

        #expect(result.imported.count == 2)
        #expect(result.targetPlaylistID == existing.id)
        #expect(result.targetPlaylistName == "Practice")
        #expect(result.openAfter == result.imported.last)
        let lastSaved = repo.savedPlaylists.last
        #expect(lastSaved?.orderedScoreItemIDs.count == 2)
        #expect(lastSaved?.orderedScoreItemIDs == result.imported)
    }

    @Test func `new playlist created then items appended`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let repo = FakeRepository()
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let token = UUID()
        try stageToken(container, token: token, newPlaylistName: "Brand new", filenames: ["a.mscz"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.count == 1)
        #expect(result.createdPlaylistID != nil)
        #expect(result.targetPlaylistName == "Brand new")
        #expect(repo.savedPlaylists.count >= 1)
        #expect(repo.savedPlaylists.first?.name == "Brand new")
    }

    @Test func `duplicate is silently resolved to existing item`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let repo = FakeRepository()
        let existing = ScoreItem(
            id: ScoreItemID(),
            title: "Existing",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "existing.mscz",
            contentHash: "dup.mscz",
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: .now,
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        repo.scoreItems = [existing]
        importer.duplicateMap = ["dup.mscz": existing]
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let token = UUID()
        try stageToken(container, token: token, openAfter: true, filenames: ["dup.mscz"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.isEmpty)
        #expect(result.skipped.count == 1)
        if case let .duplicate(existingID, _) = result.skipped[0].reason {
            #expect(existingID == existing.id)
        } else {
            Issue.record("expected duplicate reason")
        }
        #expect(result.openAfter == existing.id)
    }

    @Test func `parse failure surfaces as skip`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        importer.prepareError = NSError(domain: "Test", code: 1)
        let repo = FakeRepository()
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let token = UUID()
        try stageToken(container, token: token, filenames: ["bad.mscz"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.isEmpty)
        #expect(result.skipped.count == 1)
        if case .parseFailed = result.skipped[0].reason {} else {
            Issue.record("expected parseFailed")
        }
    }

    @Test func `drain on launch processes all tokens in order`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let repo = FakeRepository()
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let earlierToken = UUID()
        let laterToken = UUID()
        try stageToken(
            container,
            token: laterToken,
            filenames: ["later.mscz"],
            createdAt: Date(timeIntervalSince1970: 2000),
        )
        try stageToken(
            container,
            token: earlierToken,
            filenames: ["earlier.mscz"],
            createdAt: Date(timeIntervalSince1970: 1000),
        )

        let result = await coordinator.drain(token: nil)

        #expect(importer.committed.count == 2)
        #expect(importer.committed[0].0.sourceURL.lastPathComponent == "earlier.mscz")
        #expect(importer.committed[1].0.sourceURL.lastPathComponent == "later.mscz")
        let earlierPath = AppGroupPaths.tokenURL(token: earlierToken, in: container).path
        let laterPath = AppGroupPaths.tokenURL(token: laterToken, in: container).path
        #expect(!FileManager.default.fileExists(atPath: earlierPath))
        #expect(!FileManager.default.fileExists(atPath: laterPath))
        _ = result
    }
}
