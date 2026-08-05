import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

/// The §2 regression: `wireLayoutModel`'s shared `onChange` persists staffSize, honorLayoutBreaks, hiddenStaves, and
/// staffClefOverrides together. Changing ONE of them must not materialize values for the others out of their
/// untouched (`nil`) state.
@MainActor
struct ReaderUntouchedPreferencesTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    /// Mirrors `ReaderViewModelMasterVolumeTests.makeVM` — a view model over a fake repository with nothing persisted,
    /// so every preference starts untouched.
    private static func makeViewModel(repository: FakeScoreLibraryRepository) -> ReaderViewModel {
        let item = Self.makeItem()
        repository.scoreItems = [item]
        return ReaderViewModel(
            scoreItem: item,
            repository: repository,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
        )
    }

    @Test func `changing only a clef override leaves staff size and breaks nil`() async throws {
        let repo = FakeScoreLibraryRepository()
        let vm = Self.makeViewModel(repository: repo)
        await vm.loadOrSeedPreferences()
        await vm.layoutModel.setClefOverride("F", for: StaffAddress(partIndex: 0, staffIndexInPart: 0))
        let saved = try #require(repo.savedReaderPreferences.last)
        #expect(saved.staffClefOverrides.count == 1)
        #expect(saved.staffSize == nil)
        #expect(saved.honorLayoutBreaks == nil)
    }

    @Test func `toggling only a staff leaves staff size and breaks nil`() async throws {
        let repo = FakeScoreLibraryRepository()
        let vm = Self.makeViewModel(repository: repo)
        await vm.loadOrSeedPreferences()
        await vm.layoutModel.toggleStaff(StaffAddress(partIndex: 0, staffIndexInPart: 0))
        let saved = try #require(repo.savedReaderPreferences.last)
        #expect(saved.hiddenStaves.count == 1)
        #expect(saved.staffSize == nil)
        #expect(saved.honorLayoutBreaks == nil)
    }

    /// The first step away from untouched has to resolve through `effectiveStaffSize`. A mutator that read the raw
    /// `nil` slice instead would persist a size unrelated to the one the user was looking at when they tapped.
    @Test func `first staff size step from untouched persists default plus one`() async throws {
        let repo = FakeScoreLibraryRepository()
        let vm = Self.makeViewModel(repository: repo)
        await vm.loadOrSeedPreferences()
        await vm.layoutModel.incrementStaffSize()
        let saved = try #require(repo.savedReaderPreferences.last)
        #expect(saved.staffSize == 15) // the harness leaves `defaultStaffSize` at 14
    }

    /// Stepping back onto the default is still an explicit choice. `.some(default)` has to survive the re-seat
    /// through `ReaderPreferences.init` in `ReaderPreferencesStore.mutate` rather than collapsing to `nil` — only a
    /// dedicated reset affordance writes "untouched" back.
    @Test func `stepping back onto the default persists it explicitly`() async throws {
        let repo = FakeScoreLibraryRepository()
        let vm = Self.makeViewModel(repository: repo)
        await vm.loadOrSeedPreferences()
        await vm.layoutModel.incrementStaffSize()
        await vm.layoutModel.decrementStaffSize()
        let saved = try #require(repo.savedReaderPreferences.last)
        #expect(saved.staffSize == 14)
    }

    /// `wireTransposeModel` copies the model's raw Optional into the preferences. Copying `effectiveSemitones`
    /// instead would persist an explicit `0` on reset, leaving the score permanently counted as one the user
    /// transposed. `TransposeModelTests` pins the model in isolation; this pins the persistence seam.
    @Test func `transpose reset persists nil`() async throws {
        let repo = FakeScoreLibraryRepository()
        let vm = Self.makeViewModel(repository: repo)
        await vm.loadOrSeedPreferences()

        await vm.transposeModel.setSemitones(3)
        let afterSet = try #require(repo.savedReaderPreferences.last)
        #expect(afterSet.transposeSemitones == 3)

        await vm.transposeModel.reset()
        let afterReset = try #require(repo.savedReaderPreferences.last)
        #expect(afterReset.transposeSemitones == nil)
    }
}
