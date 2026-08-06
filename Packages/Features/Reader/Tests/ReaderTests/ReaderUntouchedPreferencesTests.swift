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
    private static func makeViewModel(
        repository: FakeScoreLibraryRepository,
        defaultStaffSize: Double = 12,
        defaultHonorLayoutBreaks: Bool = false,
    ) -> ReaderViewModel {
        let item = Self.makeItem()
        repository.scoreItems = [item]
        return ReaderViewModel(
            scoreItem: item,
            repository: repository,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: defaultStaffSize,
            defaultHonorLayoutBreaks: defaultHonorLayoutBreaks,
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
        #expect(saved.staffSize == 13) // the harness leaves `defaultStaffSize` at the phone default, 12
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
        #expect(saved.staffSize == 12)
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

    /// The same untouched row reads differently per device class, and reading it never marks it touched — the whole
    /// point of keeping the slice a raw Optional. A regression here is silent: the score just quietly starts counting
    /// as one the user configured.
    @Test func `the device default resolves an untouched break policy without persisting it`() async throws {
        let phoneRepo = FakeScoreLibraryRepository()
        let phone = Self.makeViewModel(repository: phoneRepo, defaultHonorLayoutBreaks: false)
        await phone.loadOrSeedPreferences()
        #expect(phone.layoutModel.honorLayoutBreaks == nil)
        #expect(phone.layoutModel.effectiveHonorLayoutBreaks == false)

        let tabletRepo = FakeScoreLibraryRepository()
        let tablet = Self.makeViewModel(
            repository: tabletRepo, defaultStaffSize: 14, defaultHonorLayoutBreaks: true,
        )
        await tablet.loadOrSeedPreferences()
        #expect(tablet.layoutModel.honorLayoutBreaks == nil)
        #expect(tablet.layoutModel.effectiveHonorLayoutBreaks == true)

        // A save triggered by an unrelated field must not materialize the resolved default.
        await tablet.layoutModel.toggleStaff(StaffAddress(partIndex: 0, staffIndexInPart: 0))
        let saved = try #require(tabletRepo.savedReaderPreferences.last)
        #expect(saved.honorLayoutBreaks == nil)
        #expect(saved.staffSize == nil)
    }
}
