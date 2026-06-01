import Domain
import Foundation
@testable import Reader
import ScoreUI
import Testing

@MainActor
struct ReaderViewModelInfoEditingTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Old", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    @Test func `loadFileMetadata returns reader's metadata`() async {
        let reader = FakeScoreMetadataReading()
        let vm = ReaderViewModel(
            scoreItem: Self.makeItem(),
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            metadataReader: reader,
            scoresDirectory: URL(filePath: "/tmp"),
        )
        let meta = await vm.loadFileMetadata(for: Self.makeItem())
        #expect(meta?.composer == "File Composer")
    }

    @Test func `saveMetadata persists trimmed fields and updates scoreItem`() async {
        let repo = FakeScoreLibraryRepository()
        let item = Self.makeItem()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
        )
        let fields = EditableScoreInfo(
            title: "  New Title  ", subtitle: "", composer: " Bach ",
            arranger: "", lyricist: "", copyright: "",
        )

        await vm.saveMetadata(item, fields: fields)

        #expect(vm.scoreItem.title == "New Title")
        #expect(vm.scoreItem.composer == "Bach")
        #expect(repo.savedScoreItems.last?.title == "New Title")
    }

    @Test func `saveMetadata with blank title is a no-op`() async {
        let repo = FakeScoreLibraryRepository()
        let item = Self.makeItem()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
        )
        await vm.saveMetadata(item, fields: EditableScoreInfo(
            title: "   ", subtitle: "", composer: "", arranger: "", lyricist: "", copyright: "",
        ))
        #expect(vm.scoreItem.title == "Old")
    }
}
