import Domain
import Foundation
@testable import Library
import ScoreUI
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

    private static func template(_ id: String) throws -> ScoreCreationTemplate {
        try #require(ScoreCreationTemplate.all.first { $0.id == id })
    }

    private static func instrument(_ id: String) throws -> ScoreInstrument {
        try #require(ScoreInstrument.instrument(id: id))
    }

    /// The catalog name the wizard would show for `id`. Read through ScoreUI rather than hard-coded: the test
    /// host resolves `String(localized:)` against the process language, so "Violin" is only right when the
    /// process happens to run in English.
    private static func name(_ id: String) throws -> String {
        try localizedInstrumentName(instrument(id))
    }

    private static func makeViewModel(
        repository: FakeScoreLibraryRepository = FakeScoreLibraryRepository(),
        gateway: FakeScoreFileGateway = FakeScoreFileGateway(),
        creator: FakeScoreFileCreator,
        crashReporter: SpyCrashReporter = SpyCrashReporter(),
    ) -> LibraryViewModel {
        LibraryViewModel(
            repository: repository,
            originalStore: FakeScoreOriginalStore(),
            importer: FakeScoreFileImporter(),
            gateway: gateway,
            shareService: FakeScoreShareService(),
            metadataReader: FakeScoreMetadataReading(),
            creator: creator,
            scoresDirectory: URL(filePath: "/tmp/folino-tests"),
            crashReporter: crashReporter,
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
        form.concertKey = -3
        form.timeNumerator = 6
        form.timeDenominator = 8
        form.tempoBPM = 72
        form.measureCount = 16
        let template = try #require(form.template())
        #expect(template.title == "Sonata")
        #expect(template.composer == nil)
        // A fresh form opens on the solo-piano template: one grand-staff part.
        #expect(template.parts.count == 1)
        #expect(template.parts[0].instrumentID == "piano")
        #expect(template.parts[0].staves.count == 2)
        #expect(template.concertKey == -3)
        #expect(template.timeNumerator == 6)
        #expect(template.measureCount == 16)
    }

    @Test
    func `template expansion builds a multi-part blank template`() throws {
        var form = NewScoreForm()
        form.title = "Q"
        try form.applyTemplate(Self.template("string-quartet"))
        let template = try #require(form.template())
        #expect(template.parts.count == 4)
        #expect(template.bracketGroups == [0 ..< 4])
        #expect(template.parts[2].staves.first?.clefType == "C3")
    }

    @Test
    func `duplicate instruments are numbered in the list and in the part names`() throws {
        var form = NewScoreForm()
        form.title = "Q"
        try form.applyTemplate(Self.template("string-quartet"))
        let violin = try Self.name("violin")
        let expected = try ["\(violin) 1", "\(violin) 2", Self.name("viola"), Self.name("violoncello")]
        #expect(form.instrumentation.map(\.displayName) == expected)
        let template = try #require(form.template())
        #expect(template.parts.map(\.longName) == expected)
    }

    @Test
    func `numbering is recomputed when the list changes`() throws {
        var form = NewScoreForm()
        try form.applyTemplate(Self.template("string-quartet"))
        form.removeInstruments(at: IndexSet(integer: 0))
        let violin = try Self.name("violin")
        let viola = try Self.name("viola")
        let cello = try Self.name("violoncello")
        // The surviving violin is no longer a duplicate, so it loses its number.
        #expect(form.instrumentation.map(\.displayName) == [violin, viola, cello])
        try form.addInstrument(Self.instrument("viola"))
        #expect(form.instrumentation.map(\.displayName) == [violin, "\(viola) 1", cello, "\(viola) 2"])
    }

    @Test
    func `manual edits clear the template's bracket groups`() throws {
        var form = NewScoreForm()
        try form.applyTemplate(Self.template("satb"))
        #expect(form.bracketGroups == [0 ..< 4])
        form.moveInstruments(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(form.bracketGroups.isEmpty)
    }

    @Test
    func `clone instrumentation copies a transposing part`() throws {
        let clarinet = BlankScoreTemplate.PartPlan(
            instrumentID: "clarinet-bb", longName: "Clarinet in B\u{266D}",
            staves: [.init(clefType: "G")], transposeDiatonic: -1,
            transposeChromatic: -2, gmProgram: 71,
        )
        let source = Score.blank(BlankScoreTemplate(
            title: "S", parts: [clarinet], measureCount: 1,
        ))
        var form = NewScoreForm()
        form.title = "T"
        form.applyInstrumentation(of: source)
        let template = try #require(form.template())
        #expect(template.parts.count == 1)
        #expect(template.parts[0].instrumentID == "clarinet-bb")
        #expect(template.parts[0].transposeDiatonic == -1)
        #expect(template.parts[0].transposeChromatic == -2)
        #expect(template.parts[0].gmProgram == 71)
        #expect(template.parts[0].staves.first?.clefType == "G")
        #expect(form.instrumentation.map(\.displayName) == ["Clarinet in B\u{266D}"])
    }

    @Test
    func `clone instrumentation copies staff shape, percussion and bracket-free grouping`() throws {
        let source = Score.blank(BlankScoreTemplate(
            title: "S",
            parts: [
                .init(instrumentID: "piano", longName: "Piano", staves: [
                    .init(clefType: "G"), .init(clefType: "F"),
                ]),
                .init(instrumentID: "drumset", longName: "Drum Kit", staves: [
                    .init(clefType: "PERC", isPercussion: true),
                ], isDrums: true),
            ],
            bracketGroups: [0 ..< 2],
            measureCount: 1,
        ))
        var form = NewScoreForm()
        form.title = "T"
        form.applyInstrumentation(of: source)
        let template = try #require(form.template())
        #expect(template.parts.count == 2)
        #expect(template.parts[0].staves.map(\.clefType) == ["G", "F"])
        #expect(template.parts[1].staves.first?.isPercussion == true)
        #expect(template.parts[1].isDrums)
        // The source's group bracket is not cloned — see `applyInstrumentation(of:)`.
        #expect(template.bracketGroups.isEmpty)
    }

    @Test
    func `an empty instrumentation disables create`() {
        var form = NewScoreForm()
        form.title = "T"
        form.instrumentation = []
        #expect(form.template() == nil)
    }

    @Test
    func `createScore hands the built score to the creator and arms the edit-session open`() async {
        let item = Self.makeItem()
        let creator = FakeScoreFileCreator(result: .success(item))
        let viewModel = Self.makeViewModel(creator: creator)
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
        let viewModel = Self.makeViewModel(creator: creator, crashReporter: crashReporter)
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

    @Test
    func `a failed instrumentation load surfaces through the sheet's alert channel`() async {
        let gateway = FakeScoreFileGateway()
        gateway.loadScoreError = .scoreFileNotFound(name: "Sonata.mscx")
        let viewModel = Self.makeViewModel(
            gateway: gateway,
            creator: FakeScoreFileCreator(result: .success(Self.makeItem())),
        )
        let loaded = await viewModel.instrumentation(of: Self.makeItem())
        #expect(loaded == nil)
        #expect(viewModel.currentError != nil)
    }
}
