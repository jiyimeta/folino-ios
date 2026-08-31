import Domain
import Foundation
@testable import Library
import ScoreUI
import Testing

@MainActor
@Suite("New score creation")
struct NewScoreTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)
    /// Never touched — every gateway in this suite is a fake. It exists so the URL a caller builds from it can
    /// be asserted against.
    private static let scoresDirectory = URL(filePath: "/tmp/folino-tests")

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
            scoresDirectory: scoresDirectory,
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

    /// Two of the same instrument are two rows with the same name, in the list and on the page. Naming them
    /// apart is the user's to do in the list's fields, not something the form does behind them.
    @Test
    func `duplicate instruments keep the plain instrument name`() throws {
        var form = NewScoreForm()
        form.title = "Q"
        try form.applyTemplate(Self.template("string-quartet"))
        let violin = try Self.name("violin")
        let expected = try [violin, violin, Self.name("viola"), Self.name("violoncello")]
        #expect(form.instrumentation.map(\.name) == expected)
        let template = try #require(form.template())
        #expect(template.parts.map(\.longName) == expected)
        let abbreviation = try Self.instrument("violin").englishAbbreviation
        #expect(template.parts[0].shortName == abbreviation)
        #expect(template.parts[1].shortName == abbreviation)
    }

    /// A renamed row builds under the name the user gave it, abbreviation untouched.
    @Test
    func `a renamed part builds under its new name`() throws {
        var form = NewScoreForm()
        form.title = "Q"
        try form.applyTemplate(Self.template("string-quartet"))
        form.instrumentation[0].name = "1st Violin"
        let template = try #require(form.template())
        #expect(template.parts[0].longName == "1st Violin")
        #expect(try template.parts[0].shortName == Self.instrument("violin").englishAbbreviation)
    }

    /// Clearing the field does not build an unlabeled staff: an empty name means "named after its instrument",
    /// which is what the row started as.
    @Test
    func `an emptied part name falls back to the instrument name`() throws {
        var form = NewScoreForm()
        form.title = "Q"
        try form.applyTemplate(Self.template("string-quartet"))
        form.instrumentation[0].name = "   "
        #expect(try form.instrumentation[0].resolvedName == Self.name("violin"))
        let template = try #require(form.template())
        #expect(try template.parts[0].longName == Self.name("violin"))
    }

    /// The abbreviation is what gets engraved from the second system on, so an edited one has to reach the part.
    @Test
    func `an edited abbreviation reaches the built part`() throws {
        var form = NewScoreForm()
        form.title = "Q"
        try form.applyTemplate(Self.template("string-quartet"))
        form.instrumentation[0].shortName = "Vln. I"
        let template = try #require(form.template())
        #expect(template.parts[0].shortName == "Vln. I")
        // Independent of the long name, which the row edits separately.
        #expect(try template.parts[0].longName == Self.name("violin"))
    }

    /// Clearing it means "no label", not "fall back to the instrument's" — the long name's empty rule does not
    /// apply here, because a staff with no abbreviation is a choice some scores make.
    @Test
    func `a cleared abbreviation builds a part without one`() throws {
        var form = NewScoreForm()
        form.title = "Q"
        try form.applyTemplate(Self.template("string-quartet"))
        form.instrumentation[0].shortName = nil
        let template = try #require(form.template())
        #expect(template.parts[0].shortName == nil)
    }

    /// Renaming is not a structural edit: the ensemble still holds the instruments the template put in it, in the
    /// same order, so its bracket grouping and its provenance stamp both survive.
    @Test
    func `renaming a part keeps the template's grouping and provenance`() throws {
        var form = NewScoreForm()
        try form.applyTemplate(Self.template("satb"))
        form.instrumentation[0].name = "Cantus"
        #expect(form.bracketGroups == [0 ..< 4])
        #expect(form.instrumentationSource == "satb")
    }

    /// A catalog pick must carry an abbreviation even when nothing is duplicated: a nil `shortName` engraves an
    /// empty staff label from the second system on.
    @Test
    func `a lone catalog part still carries a staff abbreviation`() throws {
        var form = NewScoreForm()
        form.title = "T"
        let flute = try Self.instrument("flute")
        form.replaceInstrumentation(with: flute)
        let template = try #require(form.template())
        #expect(template.parts.count == 1)
        #expect(template.parts[0].shortName == flute.englishAbbreviation)
    }

    @Test
    func `the list follows removals and additions in order`() throws {
        var form = NewScoreForm()
        try form.applyTemplate(Self.template("string-quartet"))
        form.removeInstruments(at: IndexSet(integer: 0))
        let violin = try Self.name("violin")
        let viola = try Self.name("viola")
        let cello = try Self.name("violoncello")
        #expect(form.instrumentation.map(\.name) == [violin, viola, cello])
        try form.addInstrument(Self.instrument("viola"))
        #expect(form.instrumentation.map(\.name) == [violin, viola, cello, viola])
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
        #expect(form.instrumentation.map(\.name) == ["Clarinet in B\u{266D}"])
    }

    /// A score whose parts were renamed clones as those names, with the instrument each one plays alongside —
    /// the case that started this: five staves called "なおき", "つかさ"… that are all pianos. Without the second
    /// name the list says nothing about what the rows are.
    @Test
    func `clone instrumentation keeps the part name and names the instrument`() throws {
        let source = Score.blank(BlankScoreTemplate(
            title: "S",
            parts: [
                BlankScoreTemplate.PartPlan(
                    instrumentID: "piano", longName: "なおき", shortName: "な",
                    staves: [.init(clefType: "G")],
                ),
                BlankScoreTemplate.PartPlan(
                    instrumentID: "piano", longName: "つかさ", shortName: "つ",
                    staves: [.init(clefType: "G")],
                ),
            ],
            measureCount: 1,
        ))
        var form = NewScoreForm()
        form.title = "T"
        form.applyInstrumentation(of: source)
        #expect(form.instrumentation.map(\.name) == ["なおき", "つかさ"])
        let piano = try Self.name("piano")
        #expect(form.instrumentation.map(\.instrumentName) == [piano, piano])
        // The names the user reads on the page are still their own, not the instrument's.
        let template = try #require(form.template())
        #expect(template.parts.map(\.longName) == ["なおき", "つかさ"])
        #expect(template.parts.map(\.shortName) == ["な", "つ"])
    }

    /// An instrument id this build's catalog does not know still gets a second name where the source score has
    /// one: MuseScore keeps the instrument's own name in `trackName`, untouched by a part rename.
    @Test
    func `a cloned part of an unknown instrument falls back to the source track name`() {
        let source = Score.blank(BlankScoreTemplate(
            title: "S",
            parts: [
                BlankScoreTemplate.PartPlan(
                    instrumentID: "theremin", longName: "Solo", staves: [.init(clefType: "G")],
                ),
            ],
            measureCount: 1,
        ))
        var form = NewScoreForm()
        form.title = "T"
        form.applyInstrumentation(of: source)
        #expect(form.instrumentation[0].name == "Solo")
        #expect(form.instrumentation[0].instrumentName == source.parts[0].trackName)
    }

    @Test
    func `clone instrumentation copies staff shape, percussion and grouping`() throws {
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
        // The source's group bracket comes across as the part range it covers — the whole point of "same
        // instrumentation as an existing score" is that the created score looks like the one it was cloned from.
        #expect(template.bracketGroups == [0 ..< 2])
    }

    /// The SATB shape the QA report used: four single-staff parts with one group bracket over parts 1...3, anchored
    /// on the second part's staff (global staff index 1, span 3).
    private static func satbSource() -> Score {
        var source = Score.blank(BlankScoreTemplate(
            title: "S",
            parts: (0 ..< 4).map { index in
                .init(instrumentID: "voice-\(index)", longName: "Voice \(index)", staves: [.init(clefType: "G")])
            },
            measureCount: 1,
        ))
        source.parts[1].staves[0].brackets = [BracketItem(type: .normal, span: 3)]
        return source
    }

    @Test
    func `clone derives a part-range group from a cross-part bracket`() throws {
        var form = NewScoreForm()
        form.title = "T"
        form.applyInstrumentation(of: Self.satbSource())
        let template = try #require(form.template())
        #expect(template.parts.count == 4)
        #expect(template.bracketGroups == [1 ..< 4])
        // The created score engraves it back onto the group's first part, spanning its three staves.
        let created = Score.blank(template)
        #expect(created.parts[1].staves[0].brackets.map(\.type) == [.normal])
        #expect(created.parts[1].staves[0].brackets.map(\.span) == [3])
    }

    @Test
    func `clone skips a grand staff's own brace`() throws {
        let source = Score.blank(BlankScoreTemplate(
            title: "S",
            parts: [
                .init(instrumentID: "piano", longName: "Piano", staves: [
                    .init(clefType: "G"), .init(clefType: "F"),
                ]),
            ],
            measureCount: 1,
        ))
        // `Score.blank` gave the two-staff part its brace; nothing else is bracketed.
        #expect(source.parts[0].staves[0].brackets.map(\.type) == [.brace])
        var form = NewScoreForm()
        form.title = "T"
        form.applyInstrumentation(of: source)
        let template = try #require(form.template())
        #expect(template.bracketGroups.isEmpty)
        // The brace is still there — the factory re-derives it for any multi-staff part.
        #expect(Score.blank(template).parts[0].staves[0].brackets.map(\.type) == [.brace])
    }

    @Test
    func `clone expands a bracket that ends inside a part to the whole part`() throws {
        // Parts: [solo(1 staff), piano(2 staves)]. The bracket covers global staves 0...1 — the solo staff and only
        // the piano's TOP staff — which no part range can express, so it expands to cover the piano outright.
        var source = Score.blank(BlankScoreTemplate(
            title: "S",
            parts: [
                .init(instrumentID: "flute", longName: "Flute", staves: [.init(clefType: "G")]),
                .init(instrumentID: "piano", longName: "Piano", staves: [
                    .init(clefType: "G"), .init(clefType: "F"),
                ]),
            ],
            measureCount: 1,
        ))
        source.parts[0].staves[0].brackets = [BracketItem(type: .normal, span: 2)]
        var form = NewScoreForm()
        form.title = "T"
        form.applyInstrumentation(of: source)
        let template = try #require(form.template())
        #expect(template.bracketGroups == [0 ..< 2])
    }

    @Test
    func `a non-normal group bracket clones as a normal one`() throws {
        var source = Self.satbSource()
        source.parts[1].staves[0].brackets = [BracketItem(type: .square, span: 3)]
        var form = NewScoreForm()
        form.title = "T"
        form.applyInstrumentation(of: source)
        let template = try #require(form.template())
        // `bracketGroups` carries no style, so the square bracket comes back as `.normal` — documented on
        // `partBracketGroups(of:)`.
        #expect(template.bracketGroups == [1 ..< 4])
        #expect(Score.blank(template).parts[1].staves[0].brackets.map(\.type) == [.normal])
    }

    @Test
    func `editing a cloned instrumentation drops its derived grouping`() {
        var form = NewScoreForm()
        form.title = "T"
        form.applyInstrumentation(of: Self.satbSource())
        #expect(form.bracketGroups == [1 ..< 4])
        form.removeInstruments(at: IndexSet(integer: 0))
        #expect(form.bracketGroups.isEmpty)
    }

    // MARK: - Pickup

    /// Eighth-note granularity in 4/4, stopping one unit short of the full bar: a pickup as long as the bar is
    /// not a pickup. The whole note is not offered for the same reason — 1/1 *is* the bar.
    @Test
    func `pickup menus are eighth-note multiples shorter than the bar`() {
        #expect(NewScoreForm.pickupDenominators(numerator: 4, denominator: 4) == [2, 4, 8])
        #expect(NewScoreForm.pickupNumerators(over: 8, numerator: 4, denominator: 4) == [1, 2, 3, 4, 5, 6, 7])
        #expect(NewScoreForm.pickupNumerators(over: 4, numerator: 4, denominator: 4) == [1, 2, 3])
        #expect(NewScoreForm.pickupNumerators(over: 2, numerator: 4, denominator: 4) == [1])
    }

    /// A meter finer than an eighth gets its own unit, so 3/16 can start on a sixteenth.
    @Test
    func `a fine meter offers its own denominator as the pickup unit`() {
        #expect(NewScoreForm.pickupDenominators(numerator: 3, denominator: 16) == [8, 16])
        #expect(NewScoreForm.pickupNumerators(over: 16, numerator: 3, denominator: 16) == [1, 2])
        #expect(NewScoreForm.pickupNumerators(over: 8, numerator: 3, denominator: 16) == [1])
    }

    /// A note value finer than the meter's own granularity is not offered: 3/4 is written in eighths, so there is
    /// no sixteenth-note pickup to pick. Nothing is lost by leaving it out — every length a sixteenth could spell
    /// there is an even count, which is to say an eighth-note count already on the offered menu.
    @Test
    func `a note value finer than the meter's granularity is not offered`() {
        #expect(!NewScoreForm.pickupDenominators(numerator: 3, denominator: 4).contains(16))
        let overSixteenths = NewScoreForm.pickupNumerators(over: 16, numerator: 3, denominator: 4)
        #expect(!overSixteenths.isEmpty)
        #expect(overSixteenths.allSatisfy { $0.isMultiple(of: 2) })
        #expect(overSixteenths.map { $0 / 2 } == NewScoreForm.pickupNumerators(
            over: 8, numerator: 3, denominator: 4,
        ))
    }

    @Test
    func `a chosen pickup reaches the blank-score template`() throws {
        var form = NewScoreForm()
        form.title = "Anacrusis"
        form.pickup = Fraction(numerator: 1, denominator: 4)
        let template = try #require(form.template())
        #expect(template.pickup == Fraction(numerator: 1, denominator: 4))
    }

    /// The default is no pickup at all — every bar follows the time signature, as before the option existed.
    @Test
    func `a form without a pickup builds a template without one`() throws {
        var form = NewScoreForm()
        form.title = "Plain"
        let template = try #require(form.template())
        #expect(template.pickup == nil)
    }

    /// Changing the meter can leave the chosen pickup longer than the bar it opens; the form drops it rather than
    /// building a score whose first bar is longer than its time signature.
    @Test
    func `changing the meter clears a pickup that no longer fits`() {
        var form = NewScoreForm()
        form.title = "Anacrusis"
        form.pickup = Fraction(numerator: 1, denominator: 4)
        form.timeNumerator = 1
        form.timeDenominator = 8
        #expect(form.pickup == nil)
        #expect(NewScoreForm.pickupDenominators(numerator: 1, denominator: 8).isEmpty)
    }

    /// ...but a pickup the new meter still accommodates survives the change.
    @Test
    func `changing the meter keeps a pickup that still fits`() {
        var form = NewScoreForm()
        form.title = "Anacrusis"
        form.pickup = Fraction(numerator: 1, denominator: 8)
        form.timeNumerator = 6
        form.timeDenominator = 8
        #expect(form.pickup == Fraction(numerator: 1, denominator: 8))
    }

    /// The meter's two menus write one binding each, so moving from 7/8 to 3/4 asks the form about a meter that
    /// never existed — here 3/8, between them. A 5/8 pickup does not fit that transient bar but fits 3/4 exactly,
    /// and must survive the crossing.
    @Test
    func `a meter change through a shorter transient bar keeps a fitting pickup`() {
        let pickup = Fraction(numerator: 5, denominator: 8)
        var form = NewScoreForm()
        form.title = "Anacrusis"
        form.timeNumerator = 7
        form.timeDenominator = 8
        form.pickup = pickup
        #expect(form.pickup == pickup)
        // The trap, pinned: judged against the half-written meter, this pickup looks unavailable.
        #expect(!NewScoreForm.pickupNumerators(over: 8, numerator: 3, denominator: 8).contains(5))
        // One menu, then the other.
        form.timeNumerator = 3
        form.timeDenominator = 4
        #expect(form.pickup == pickup)
    }

    /// The same in the other write order, so neither field is special.
    @Test
    func `a meter change keeps a fitting pickup whichever field moves first`() {
        let pickup = Fraction(numerator: 5, denominator: 8)
        var form = NewScoreForm()
        form.title = "Anacrusis"
        form.timeNumerator = 7
        form.timeDenominator = 8
        form.pickup = pickup
        form.timeDenominator = 4
        form.timeNumerator = 3
        #expect(form.pickup == pickup)
    }

    /// A meter the user passes through does not cost them the pickup: it stops being offered while it does not
    /// fit, and comes back when the meter accommodates it again.
    @Test
    func `a pickup hidden by one meter returns when the meter fits it again`() {
        let pickup = Fraction(numerator: 5, denominator: 8)
        var form = NewScoreForm()
        form.title = "Anacrusis"
        form.timeNumerator = 7
        form.timeDenominator = 8
        form.pickup = pickup
        form.timeNumerator = 1
        #expect(form.pickup == nil)
        #expect(form.template()?.pickup == nil)
        form.timeNumerator = 7
        #expect(form.pickup == pickup)
    }

    /// The one-value check the `pickup` property reads through must answer exactly what the two menus offer —
    /// they are two spellings of one rule, and a drift between them would show as a picker row with no selection.
    ///
    /// Compared over the candidate's own spelling, since that is what the row shows: a beat count is reachable
    /// exactly when its note value is on the denominator menu and it is on that value's numerator menu.
    @Test
    func `pickup availability agrees with the offered menus`() {
        let meters = [(4, 4), (3, 4), (7, 8), (6, 8), (3, 16), (2, 2), (1, 8), (5, 32)]
        let candidates = [(1, 16), (1, 8), (1, 4), (3, 8), (1, 2), (5, 8), (3, 4), (7, 8), (1, 1), (3, 2), (1, 32)]
        for (numerator, denominator) in meters {
            let noteValues = NewScoreForm.pickupDenominators(numerator: numerator, denominator: denominator)
            for candidate in candidates {
                let counts = NewScoreForm.pickupNumerators(
                    over: candidate.1, numerator: numerator, denominator: denominator,
                )
                let reachable = noteValues.contains(candidate.1) && counts.contains(candidate.0)
                #expect(
                    NewScoreForm.isPickupAvailable(
                        Fraction(numerator: candidate.0, denominator: candidate.1),
                        numerator: numerator, denominator: denominator,
                    ) == reachable,
                    "\(candidate.0)/\(candidate.1) in \(numerator)/\(denominator)",
                )
            }
        }
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
        let item = Self.makeItem()
        let loaded = await viewModel.instrumentation(of: item)
        #expect(loaded == nil)
        #expect(viewModel.currentError != nil)
        // The item's file is resolved against the injected scores directory, not the process's cwd.
        #expect(gateway.lastLoadedURL == Self.scoresDirectory.appending(path: item.localFileName))
    }
}
