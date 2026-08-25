import Domain
import Foundation
@testable import Library
import ScoreUI
import Testing

@MainActor
struct LibraryViewModelRevertTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(title: String = "A") -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private static func makeVM(
        repository: FakeScoreLibraryRepository,
        originalStore: FakeScoreOriginalStore,
    ) -> LibraryViewModel {
        LibraryViewModel(
            repository: repository,
            originalStore: originalStore,
            importer: FakeScoreFileImporter(),
            gateway: FakeScoreFileGateway(),
            shareService: FakeScoreShareService(),
            metadataReader: FakeScoreMetadataReading(),
            creator: FakeScoreFileCreator(),
        )
    }

    @Test func `reverting persists the rebuilt row`() async {
        let store = FakeScoreOriginalStore()
        let repository = FakeScoreLibraryRepository()
        let vm = Self.makeVM(repository: repository, originalStore: store)
        var item = Self.makeItem()
        item.originalFileName = "ID.original.mscz"
        item.originalProvenance = .importTime

        await vm.revertToOriginal(item, restoringScoreInfo: true)

        #expect(store.revertCalls.count == 1)
        #expect(store.revertCalls.first?.1 == true)
        #expect(repository.savedScoreItems.count == 1)
        #expect(repository.savedScoreItems.first?.originalFileName == nil)
    }

    @Test func `a store failure records the error instead of saving`() async {
        let store = FakeScoreOriginalStore()
        store.revertError = DomainError.scoreWriteFailed(reason: "disk full")
        let repository = FakeScoreLibraryRepository()
        let vm = Self.makeVM(repository: repository, originalStore: store)
        var item = Self.makeItem()
        item.originalFileName = "ID.original.mscz"
        item.originalProvenance = .importTime

        await vm.revertToOriginal(item, restoringScoreInfo: false)

        #expect(store.revertCalls.first?.1 == false)
        #expect(repository.savedScoreItems.isEmpty)
        #expect(vm.currentError != nil)
    }
}
