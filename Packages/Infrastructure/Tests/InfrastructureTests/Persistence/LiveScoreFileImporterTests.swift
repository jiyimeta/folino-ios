@testable import Domain
import Foundation
@testable import Persistence
@testable import ScoreFiles
import Testing

@MainActor
@Observable
private final class FailingRepository: ScoreLibraryRepository {
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

    /// Reader preferences: no-op stubs — this fake exists to fail score-item saves; reader-pref methods aren't
    /// exercised by these tests.
    func loadReaderPreferences(for scoreItemID: ScoreItemID) throws -> ReaderPreferences? {
        nil
    }

    func saveReaderPreferences(_ preferences: ReaderPreferences) throws {}
}

@MainActor
struct LiveScoreFileImporterTests {
    private struct Rig {
        let db: AppDatabase
        let repo: LiveScoreLibraryRepository
        let scoresDir: URL
        let importer: LiveScoreFileImporter
        let lifetime: TempDirectory
        let scoresLifetime: TempDirectory

        var tmp: URL {
            lifetime.url
        }
    }

    private func makeRig() async throws -> Rig {
        let lifetime = try TempDirectory()
        let db = try AppDatabase(databaseURL: lifetime.url.appending(path: "f.sqlite"))
        let scoresLifetime = try TempDirectory()
        let scoresDir = scoresLifetime.url
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir)
        try await repo.refresh()
        let importer = LiveScoreFileImporter(
            gateway: LiveScoreFileGateway(),
            repository: repo,
            scoresDirectory: scoresDir,
        )
        return Rig(
            db: db, repo: repo, scoresDir: scoresDir,
            importer: importer, lifetime: lifetime, scoresLifetime: scoresLifetime,
        )
    }

    @Test func `prepare import returns zero duplicates for fresh file`() async throws {
        let rig = try await makeRig()
        defer { withExtendedLifetime((rig.lifetime, rig.scoresLifetime)) {} }

        let mscxURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMSCXData(), ext: "mscx", in: rig.tmp,
        )
        let plan = try await rig.importer.prepareImport(sourceURL: mscxURL)
        #expect(plan.duplicates.isEmpty)
        #expect(plan.format == .mscx)
        #expect(plan.contentHash.count == 64) // SHA-256 hex
        #expect(plan.sizeBytes > 0)
    }

    @Test func `prepare import throws for PDF`() async throws {
        let rig = try await makeRig()
        defer { withExtendedLifetime((rig.lifetime, rig.scoresLifetime)) {} }

        let pdfURL = try Fixtures.writeToTempFile(Data("dummy".utf8), ext: "pdf", in: rig.tmp)
        do {
            _ = try await rig.importer.prepareImport(sourceURL: pdfURL)
            Issue.record("expected throw")
        } catch DomainError.unsupportedFormat {
            // Expected.
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test func `prepare import throws for extension less file`() async throws {
        let rig = try await makeRig()
        defer { withExtendedLifetime((rig.lifetime, rig.scoresLifetime)) {} }

        let url = rig.tmp.appending(path: "no-ext")
        try Data("x".utf8).write(to: url)
        do {
            _ = try await rig.importer.prepareImport(sourceURL: url)
            Issue.record("expected throw")
        } catch DomainError.unsupportedFormat {
            // Expected.
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test func `commit import as new copies file and persists row`() async throws {
        let rig = try await makeRig()
        defer { withExtendedLifetime((rig.lifetime, rig.scoresLifetime)) {} }

        let mscxURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMSCXData(), ext: "mscx", in: rig.tmp,
        )
        let plan = try await rig.importer.prepareImport(sourceURL: mscxURL)
        let item = try await rig.importer.commitImport(plan, decision: .importAsNew)

        // localFileName follows <id>.<canonicalExtension>
        #expect(item.localFileName == "\(item.id.rawValue.uuidString).mscx")

        let dest = rig.scoresDir.appending(path: item.localFileName)
        #expect(FileManager.default.fileExists(atPath: dest.path))

        try await waitFor { rig.repo.scoreItems.contains { $0.id == item.id } }
    }

    @Test func `reimport same bytes yields one duplicate`() async throws {
        let rig = try await makeRig()
        defer { withExtendedLifetime((rig.lifetime, rig.scoresLifetime)) {} }

        let mscxURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMSCXData(), ext: "mscx", in: rig.tmp,
        )
        let firstPlan = try await rig.importer.prepareImport(sourceURL: mscxURL)
        _ = try await rig.importer.commitImport(firstPlan, decision: .importAsNew)
        try await waitFor { rig.repo.scoreItems.count == 1 }

        let secondPlan = try await rig.importer.prepareImport(sourceURL: mscxURL)
        #expect(secondPlan.duplicates.count == 1)
    }

    @Test func `open existing does not write new row or file`() async throws {
        let rig = try await makeRig()
        defer { withExtendedLifetime((rig.lifetime, rig.scoresLifetime)) {} }

        let mscxURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMSCXData(), ext: "mscx", in: rig.tmp,
        )
        let firstPlan = try await rig.importer.prepareImport(sourceURL: mscxURL)
        let original = try await rig.importer.commitImport(firstPlan, decision: .importAsNew)
        try await waitFor { rig.repo.scoreItems.count == 1 }

        let secondPlan = try await rig.importer.prepareImport(sourceURL: mscxURL)
        let resolved = try await rig.importer.commitImport(
            secondPlan, decision: .openExisting(original.id),
        )
        #expect(resolved.id == original.id)

        let filesBefore = try FileManager.default.contentsOfDirectory(
            at: rig.scoresDir, includingPropertiesForKeys: nil,
        ).count(where: { $0.lastPathComponent != ".staging" })
        #expect(filesBefore == 1)
        #expect(rig.repo.scoreItems.count == 1)
    }

    @Test func `save failure rolls back copied file`() async throws {
        let tmp = try TempDirectory()
        let scoresDir = tmp.url.appending(path: "Scores")
        try FileManager.default.createDirectory(at: scoresDir, withIntermediateDirectories: true)
        defer { withExtendedLifetime(tmp) {} }

        let importer = LiveScoreFileImporter(
            gateway: LiveScoreFileGateway(),
            repository: FailingRepository(),
            scoresDirectory: scoresDir,
        )
        let mscxURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMSCXData(), ext: "mscx", in: tmp.url,
        )
        let plan = try await importer.prepareImport(sourceURL: mscxURL)

        do {
            _ = try await importer.commitImport(plan, decision: .importAsNew)
            Issue.record("expected throw")
        } catch DomainError.persistenceFailed {
            // Expected.
        } catch {
            Issue.record("unexpected: \(error)")
        }

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: scoresDir, includingPropertiesForKeys: nil,
        ).filter { $0.lastPathComponent != ".staging" }
        #expect(leftovers.isEmpty)
    }
}
