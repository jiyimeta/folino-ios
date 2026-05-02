@testable import Domain
import Foundation
@testable import Persistence
@testable import ScoreFiles
import Testing

@MainActor
@Suite struct LiveScoreFileImporterTests {
    private struct Rig {
        let db: AppDatabase
        let repo: LiveScoreLibraryRepository
        let scoresDir: URL
        let importer: LiveScoreFileImporter
        let lifetime: TempDirectory
        let scoresLifetime: TempDirectory

        var tmp: URL { lifetime.url }
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
            scoresDirectory: scoresDir
        )
        return Rig(
            db: db, repo: repo, scoresDir: scoresDir,
            importer: importer, lifetime: lifetime, scoresLifetime: scoresLifetime
        )
    }

    @Test func prepareImportReturnsZeroDuplicatesForFreshFile() async throws {
        let rig = try await makeRig()
        defer { withExtendedLifetime((rig.lifetime, rig.scoresLifetime)) {} }

        let mscxURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMSCXData(), ext: "mscx", in: rig.tmp
        )
        let plan = try await rig.importer.prepareImport(sourceURL: mscxURL)
        #expect(plan.duplicates.isEmpty)
        #expect(plan.format == .mscx)
        #expect(plan.contentHash.count == 64) // SHA-256 hex
        #expect(plan.sizeBytes > 0)
    }

    @Test func prepareImportThrowsForPDF() async throws {
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

    @Test func prepareImportThrowsForExtensionLessFile() async throws {
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
}
