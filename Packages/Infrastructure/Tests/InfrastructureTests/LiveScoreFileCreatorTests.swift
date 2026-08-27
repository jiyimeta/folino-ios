import Domain
import Foundation
@testable import Persistence
@testable import ScoreFiles
import Testing
import UtilityCore

@MainActor
@Observable
private final class FailingCreatorRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = []
    var deletedScoreItems: [ScoreItem] = []
    var tags: [Domain.Tag] = []
    var playlists: [Playlist] = []

    func refresh() throws {}
    func saveScoreItem(_ item: ScoreItem) throws {
        throw DomainError.persistenceFailed(reason: "stub failure")
    }

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

    /// Reader preferences: not exercised by these tests — this fake exists to fail score-item saves. The read stubs
    /// stay empty; `allReaderPreferences` throws instead of vending `[]` so a future caller that starts depending on
    /// it fails loudly rather than silently reading a snapshot this fake never populates.
    func loadReaderPreferences(for scoreItemID: ScoreItemID) throws -> ReaderPreferences? {
        nil
    }

    func saveReaderPreferences(_ preferences: ReaderPreferences) throws {}

    func allReaderPreferences() throws -> [ReaderPreferences] {
        throw DomainError.persistenceFailed(reason: "stub failure")
    }
}

@MainActor
@Suite("LiveScoreFileCreator")
struct LiveScoreFileCreatorTests {
    @Test
    func `writes the mscx, registers the row, and derives metadata from the score`() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "creator-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase(databaseURL: dir.appending(path: "f.sqlite"))
        let repository = LiveScoreLibraryRepository(database: db, scoresDirectory: dir)
        try await repository.refresh()
        let creator = LiveScoreFileCreator(
            gateway: LiveScoreFileGateway(), repository: repository, scoresDirectory: dir,
        )

        let score = Score.blank(BlankScoreTemplate(
            title: "Test Piece", composer: "Someone",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            tempoBPM: 90, measureCount: 8,
        ))
        let item = try await creator.createScore(score)

        #expect(item.title == "Test Piece")
        #expect(item.composer == "Someone")
        #expect(item.localFileName == "\(item.id.rawValue.uuidString).mscx")
        let fileURL = dir.appending(path: item.localFileName)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let facts = try FileFacts.hashAndSize(of: fileURL)
        #expect(item.contentHash == facts.contentHash)
        #expect(item.sizeBytes == facts.sizeBytes)
        // Row landed: `LiveScoreLibraryRepository` publishes its rows on `scoreItems`, same as
        // `LiveScoreFileImporterTests` reads back a commit.
        try await waitFor { repository.scoreItems.contains { $0.id == item.id } }
    }

    /// The whole M2 creation path end to end, at the layer that actually writes the file: a template expands to parts,
    /// `LiveScoreFileCreator` encodes them, and reading the file back through the gateway yields the same ensemble.
    /// The unit tests either side of this one cover the expansion and the encoding separately — what only a round trip
    /// can show is that nothing is lost in between.
    @Test
    func `an ensemble template round-trips through the file`() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "creator-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase(databaseURL: dir.appending(path: "f.sqlite"))
        let repository = LiveScoreLibraryRepository(database: db, scoresDirectory: dir)
        try await repository.refresh()
        let gateway = LiveScoreFileGateway()
        let creator = LiveScoreFileCreator(gateway: gateway, repository: repository, scoresDirectory: dir)

        let template = try #require(ScoreCreationTemplate.all.first { $0.id == "string-quartet" })
        let item = try await creator.createScore(Score.blank(BlankScoreTemplate(
            title: "Quartet", parts: template.instruments.map { $0.partPlan() },
            bracketGroups: template.bracketGroups, measureCount: 4,
        )))

        let (reloaded, _) = try await gateway.loadScore(fileURL: dir.appending(path: item.localFileName))
        #expect(reloaded.parts.count == 4)
        #expect(reloaded.parts.map(\.instrument.id) == ["violin", "violin", "viola", "violoncello"])
        // `longName` is optional on `Instrument`; a part that came back without one reads as "" and fails here.
        #expect(reloaded.parts.map { $0.instrument.longName ?? "" } == ["Violin", "Violin", "Viola", "Cello"])
        // One staff each — a quartet is four single-staff parts, not two grand staves.
        #expect(reloaded.parts.allSatisfy { $0.staves.count == 1 })
    }

    @Test
    func `a failed row save removes the orphaned file`() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "creator-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let creator = LiveScoreFileCreator(
            gateway: LiveScoreFileGateway(), repository: FailingCreatorRepository(), scoresDirectory: dir,
        )

        let score = Score.blank(BlankScoreTemplate(
            title: "Test Piece",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
        ))
        do {
            _ = try await creator.createScore(score)
            Issue.record("expected throw")
        } catch DomainError.persistenceFailed {
            // Expected.
        } catch {
            Issue.record("unexpected: \(error)")
        }

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
        )
        #expect(leftovers.isEmpty)
    }
}
