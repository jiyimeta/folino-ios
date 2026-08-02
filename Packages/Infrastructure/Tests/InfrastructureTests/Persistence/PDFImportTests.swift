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

    private func makeRig(pdfConversion: PDFScoreConversion? = nil) async throws -> Rig {
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
            pdfConversion: pdfConversion,
        )
        return Rig(
            importer: importer, repo: repo, scoresDir: scoresDir,
            lifetime: lifetime, scoresLifetime: scoresLifetime,
        )
    }

    /// A conversion that really writes an `.mscz` (the minimal fixture's bytes), so the import path is exercised
    /// end-to-end without running OMR.
    private func succeedingConversion() -> PDFScoreConversion {
        { _, destination in
            guard let data = try? Fixtures.minimalMSCZData(), (try? data.write(to: destination)) != nil else {
                return nil
            }
            let gateway = LiveScoreFileGateway()
            guard let summary = try? await gateway.loadFileMetadata(fileURL: destination) else { return nil }
            return PDFConversionFacts(
                fileName: destination.lastPathComponent,
                contentHash: "converted-hash",
                sizeBytes: Int64(data.count),
                summary: summary,
            )
        }
    }

    private func failingConversion() -> PDFScoreConversion {
        { _, _ in nil }
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

    @Test func `importing a readable PDF stores the converted score and keeps the original`() async throws {
        let rig = try await makeRig(pdfConversion: succeedingConversion())
        defer { withExtendedLifetime((rig.lifetime, rig.scoresLifetime)) {} }

        let src = try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
        let plan = try await rig.importer.prepareImport(sourceURL: src)
        let item = try await rig.importer.commitImport(plan, decision: .importAsNew)

        #expect(item.localFileName == "\(item.id.rawValue.uuidString).mscz")
        #expect(item.sourcePDFFileName == "\(item.id.rawValue.uuidString).pdf")
        #expect(item.sourcePDFContentHash == plan.contentHash)
        #expect(item.pdfDerivedContentHash == item.contentHash)
        #expect(!item.pdfConversionFailed)
        #expect(item.pdfOriginState == .converted)
        // The title still comes from the file name, never from the notation the parse produced.
        #expect(item.title == "sample")
        #expect(FileManager.default.fileExists(
            atPath: rig.scoresDir.appending(path: item.localFileName).path,
        ))
        #expect(try FileManager.default.fileExists(
            atPath: rig.scoresDir.appending(path: #require(item.sourcePDFFileName)).path,
        ))
    }

    @Test func `an unreadable PDF imports as a PDF item and remembers the failure`() async throws {
        let rig = try await makeRig(pdfConversion: failingConversion())
        defer { withExtendedLifetime((rig.lifetime, rig.scoresLifetime)) {} }

        let src = try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
        let plan = try await rig.importer.prepareImport(sourceURL: src)
        let item = try await rig.importer.commitImport(plan, decision: .importAsNew)

        #expect(item.localFileName == "\(item.id.rawValue.uuidString).pdf")
        #expect(item.contentHash == plan.contentHash)
        #expect(item.pdfConversionFailed)
        #expect(item.pdfOriginState == .unconverted)
    }

    @Test func `a converted PDF is still recognized when the same file is imported again`() async throws {
        let rig = try await makeRig(pdfConversion: succeedingConversion())
        defer { withExtendedLifetime((rig.lifetime, rig.scoresLifetime)) {} }

        let src = try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
        let first = try await rig.importer.prepareImport(sourceURL: src)
        let item = try await rig.importer.commitImport(first, decision: .importAsNew)

        let second = try await rig.importer.prepareImport(sourceURL: src)
        #expect(second.duplicates.map(\.id) == [item.id])
    }
}
