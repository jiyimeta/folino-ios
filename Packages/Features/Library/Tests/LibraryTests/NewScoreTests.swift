import Domain
import Foundation
@testable import Library
import Testing

@MainActor
@Suite("New score creation")
struct NewScoreTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(title: String = "Sonata") -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    // `ScoreFileCreator: Sendable` needs an explicit `@unchecked` opt-out for a mutable class under strict
    // concurrency — mirrors `FakeScoreFileGateway`'s `@unchecked Sendable` in the shared Fakes/.
    final class FakeScoreFileCreator: ScoreFileCreator, @unchecked Sendable {
        var created: [Score] = []
        var result: Result<ScoreItem, Error>
        init(result: Result<ScoreItem, Error>) {
            self.result = result
        }

        func createScore(_ score: Score) throws -> ScoreItem {
            created.append(score)
            return try result.get()
        }
    }

    @Test
    func `form without a title produces no template`() {
        var form = NewScoreForm()
        form.title = "   "
        #expect(form.template() == nil)
    }

    @Test
    func `form maps to the blank-score template`() throws {
        var form = NewScoreForm()
        form.title = " Sonata "
        form.composer = ""
        form.preset = .piano
        form.concertKey = -3
        form.timeNumerator = 6
        form.timeDenominator = 8
        form.tempoBPM = 72
        form.measureCount = 16
        let template = try #require(form.template())
        #expect(template.title == "Sonata")
        #expect(template.composer == nil)
        #expect(template.staves.count == 2)
        #expect(template.concertKey == -3)
        #expect(template.timeNumerator == 6)
        #expect(template.measureCount == 16)
    }

    @Test
    func `createScore hands the built score to the creator and arms the edit-session open`() async {
        let item = Self.makeItem()
        let creator = FakeScoreFileCreator(result: .success(item))
        let viewModel = LibraryViewModel(
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            importer: FakeScoreFileImporter(),
            gateway: FakeScoreFileGateway(),
            shareService: FakeScoreShareService(),
            metadataReader: FakeScoreMetadataReading(),
            creator: creator,
        )
        var form = NewScoreForm()
        form.title = "Sonata"
        await viewModel.createScore(from: form)
        #expect(creator.created.count == 1)
        #expect(viewModel.pendingScoreToOpen == item)
        #expect(viewModel.consumePendingOpenInEditSession())
        #expect(!viewModel.consumePendingOpenInEditSession()) // one-shot
        #expect(!viewModel.isNewScoreSheetPresented)
    }

    @Test
    func `createScore failure surfaces the error, records it, and keeps the sheet presented`() async {
        let creator = FakeScoreFileCreator(result: .failure(DomainError.persistenceFailed(reason: "disk full")))
        let crashReporter = SpyCrashReporter()
        let viewModel = LibraryViewModel(
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            importer: FakeScoreFileImporter(),
            gateway: FakeScoreFileGateway(),
            shareService: FakeScoreShareService(),
            metadataReader: FakeScoreMetadataReading(),
            creator: creator,
            crashReporter: crashReporter,
        )
        // Mirrors the real flow: the sheet is already presented (the user tapped Create from within it).
        viewModel.isNewScoreSheetPresented = true
        var form = NewScoreForm()
        form.title = "Sonata"
        await viewModel.createScore(from: form)
        #expect(creator.created.count == 1)
        #expect(viewModel.currentError is ScoreCreationFailed)
        #expect(viewModel.isNewScoreSheetPresented) // stays up — the sheet's own alert surfaces the error
        #expect(viewModel.pendingScoreToOpen == nil)
        #expect(!viewModel.consumePendingOpenInEditSession())
        #expect(crashReporter.recordedErrors.count == 1)
    }
}
