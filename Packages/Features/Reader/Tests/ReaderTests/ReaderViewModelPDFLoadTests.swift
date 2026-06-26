import Domain
import Foundation
@testable import Reader
import Testing

@MainActor
struct ReaderViewModelPDFLoadTests {
    /// Stages a copy of the bundled `sample.pdf` into a temp scores directory as `<id>.pdf`, returns the matching
    /// `ScoreItem` plus the directory so the view model can resolve the file the way it does in production.
    private func makePDFItem() throws -> (item: ScoreItem, scoresDirectory: URL) {
        let source = try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
        let id = ScoreItemID()
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ReaderPDFLoadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let localFileName = "\(id.rawValue.uuidString).pdf"
        try FileManager.default.copyItem(at: source, to: dir.appending(path: localFileName))
        let item = ScoreItem(
            id: id,
            title: "Sample Title", composer: nil, instrumentationSummary: nil,
            localFileName: localFileName, contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 0, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        return (item, dir)
    }

    @Test func `loads PDF into loaded PDF state`() async throws {
        let (item, dir) = try makePDFItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: dir,
        )

        await vm.load()
        guard case let .loadedPDF(doc) = vm.loadState else {
            Issue.record("expected .loadedPDF, got \(vm.loadState)")
            return
        }
        #expect(doc.pageCount > 0)
        #expect(vm.capabilities == .forPDF)
        #expect(vm.loadState.score == nil)
    }
}
