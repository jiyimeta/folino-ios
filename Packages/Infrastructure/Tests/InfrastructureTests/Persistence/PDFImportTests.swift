@testable import Domain
import Foundation
@testable import Persistence
@testable import ScoreFiles
import Testing

@MainActor
struct PDFImportTests {
    private struct Rig {
        let importer: LiveScoreFileImporter
        let repo: LiveScoreLibraryRepository
        let scoresDir: URL
        let lifetime: TempDirectory
        let scoresLifetime: TempDirectory
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
            importer: importer, repo: repo, scoresDir: scoresDir,
            lifetime: lifetime, scoresLifetime: scoresLifetime,
        )
    }

    /// `sample.pdf` carries `/Title = "Sample Title"`, which must NOT win over the file name — exporters (MuseScore in
    /// particular) bake an internal project name into `/Title` that has nothing to do with what the user filed away.
    @Test func `imports PDF as new item titled after the source file name`() async throws {
        let rig = try await makeRig()
        defer { withExtendedLifetime((rig.lifetime, rig.scoresLifetime)) {} }

        let src = try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
        let plan = try await rig.importer.prepareImport(sourceURL: src)
        #expect(plan.format == .pdf)
        #expect(plan.summary.title == "Sample Title")

        let item = try await rig.importer.commitImport(plan, decision: .importAsNew)
        #expect(item.localFileName == "\(item.id.rawValue.uuidString).pdf")
        #expect(item.title == "sample")
        #expect(item.lengthBeats == 0)
        #expect(ScoreFormat.detect(filename: item.localFileName) == .pdf)
    }
}
