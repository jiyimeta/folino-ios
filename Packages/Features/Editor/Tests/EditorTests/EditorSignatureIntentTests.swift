import Domain
@testable import Editor
import Foundation
import Testing

/// Pins the signature-change surface: the `EditIntent` each of the four ops constructs (read through the DEBUG
/// `appliedIntents` seam, the way `EditorIntentConstructionTests` does), what the sheets read to open on the right
/// value, and the three outcomes an apply can have — landed, refused, or nothing to do.
///
/// The last of those is the one worth stating in tests: ssm answers "the score already says this" with the same
/// `false` it answers a real refusal with, and surfacing `.nothingToApply` as an alert would put an error in front
/// of a user who picked the key the bar is already in.
@MainActor
@Suite("Editor signature intents")
struct EditorSignatureIntentTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
    }

    // MARK: - Fixtures

    private static func quarterRests(_ count: Int) -> [VoiceElement] {
        Array(repeating: .rest(duration: .quarter), count: count)
    }

    /// `threeMeasuresOfQuarterRests` with an explicit E♭ major key opening bar 1 — a mid-piece key change, which is
    /// what the Remove row is gated on. Bar 1's rests therefore start at element index 1.
    private static func keyChangeAtBarOne() -> Score {
        var score = EditorFixtures.threeMeasuresOfQuarterRests()
        score.parts[0].staves[0].measures[1].voices[0].elements.insert(
            .keySignature(KeySignature(concertKey: -3)), at: 0,
        )
        return score
    }

    /// Three bars where bar 1 declares 2/4 of its own and bar 2 inherits it — an explicit mid-piece meter change in
    /// a score whose bars actually hold what they declare.
    private static func timeChangeAtBarOne() -> Score {
        let opening = Voice(elements: [.timeSignature(TimeSignature(numerator: 4, denominator: 4))] + quarterRests(4))
        let change = Voice(elements: [.timeSignature(TimeSignature(numerator: 2, denominator: 4))] + quarterRests(2))
        let staff = Staff(measures: [
            Measure(voices: [opening]),
            Measure(voices: [change]),
            Measure(voices: [Voice(elements: quarterRests(2))]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "x"), staves: [staff]),
        ])
    }

    /// One 4/4 bar of quarter, triplet, quarter, quarter. Re-barring it at 3/8 puts a barline at tick 720, inside
    /// the triplet — the engine refuses the whole operation with `.rebarWouldSplitTuplet`.
    private static func straddlingTriplet() -> Score {
        let triplet = VoiceElement.rest(duration: .fraction(Fraction(numerator: 1, denominator: 12)))
        let note = VoiceElement.chord(Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)]))
        let voice = Voice(
            elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                note, triplet, triplet, triplet, note, note,
            ],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 4)],
        )
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [Measure(voices: [voice])])]),
        ])
    }

    /// A view model in a session on `score` with bar `measure`'s first rest picked — which is what supplies
    /// `targetMeasureIndex`.
    private func viewModel(on score: Score, targeting measure: Int, element: Int = 0) -> EditorViewModel {
        let vm = makeViewModel()
        vm.beginSession(score: score)
        vm.select(.rest(EditorFixtures.restID(measure: measure, element: element)))
        return vm
    }

    // MARK: - Intent construction

    @Test func `setKeySignature addresses the target bar`() {
        let vm = viewModel(on: EditorFixtures.threeMeasuresOfQuarterRests(), targeting: 2)
        vm.setKeySignature(concertKey: -2)
        #expect(vm.appliedIntents == [.setKeySignature(measureIndex: 2, concertKey: -2)])
    }

    @Test func `removeKeySignatureChange addresses the target bar`() {
        let vm = viewModel(on: Self.keyChangeAtBarOne(), targeting: 1, element: 1)
        vm.removeKeySignatureChange()
        #expect(vm.appliedIntents == [.removeKeySignature(measureIndex: 1)])
    }

    @Test func `setTimeSignature addresses the target bar`() {
        let vm = viewModel(on: EditorFixtures.threeMeasuresOfQuarterRests(), targeting: 2)
        vm.setTimeSignature(numerator: 3, denominator: 4)
        #expect(vm.appliedIntents == [.setTimeSignature(measureIndex: 2, numerator: 3, denominator: 4)])
    }

    @Test func `removeTimeSignatureChange addresses the target bar`() {
        let vm = viewModel(on: Self.timeChangeAtBarOne(), targeting: 1, element: 1)
        vm.removeTimeSignatureChange()
        #expect(vm.appliedIntents == [.removeTimeSignature(measureIndex: 1)])
    }

    @Test func `all four are no-ops without a target`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.threeMeasuresOfQuarterRests())
        #expect(vm.targetMeasureIndex == nil)
        #expect(!vm.setKeySignature(concertKey: -2))
        #expect(!vm.removeKeySignatureChange())
        #expect(!vm.setTimeSignature(numerator: 3, denominator: 4))
        #expect(!vm.removeTimeSignatureChange())
        #expect(vm.appliedIntents.isEmpty)
    }

    // MARK: - What the sheets open showing

    @Test func `the target's key and meter are the ones in force there`() {
        let vm = viewModel(on: Self.keyChangeAtBarOne(), targeting: 2)
        #expect(vm.targetConcertKey == -3) // inherited from bar 1's change
        #expect(vm.targetTimeSignature == EditorTimeSignatureValue(numerator: 4, denominator: 4))
    }

    @Test func `the meter in force is the declaration, not the bar's length`() {
        let vm = viewModel(on: Self.timeChangeAtBarOne(), targeting: 2)
        #expect(vm.targetTimeSignature == EditorTimeSignatureValue(numerator: 2, denominator: 4))
    }

    @Test func `neither is answered without a target`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.threeMeasuresOfQuarterRests())
        #expect(vm.targetConcertKey == nil)
        #expect(vm.targetTimeSignature == nil)
    }

    // MARK: - Whether the target declares a change of its own

    @Test func `an explicit key change is seen only on the bar that carries it`() {
        let score = Self.keyChangeAtBarOne()
        #expect(viewModel(on: score, targeting: 1, element: 1).targetHasExplicitKeyChange)
        #expect(!viewModel(on: score, targeting: 2).targetHasExplicitKeyChange)
        // Bar 0's signature is the score's key, not a change to it — the Remove row never offers it.
        #expect(!viewModel(on: score, targeting: 0, element: 1).targetHasExplicitKeyChange)
    }

    @Test func `an explicit meter change is seen only on the bar that carries it`() {
        let score = Self.timeChangeAtBarOne()
        #expect(viewModel(on: score, targeting: 1, element: 1).targetHasExplicitTimeChange)
        #expect(!viewModel(on: score, targeting: 2).targetHasExplicitTimeChange)
        #expect(!viewModel(on: score, targeting: 0, element: 1).targetHasExplicitTimeChange)
    }

    // MARK: - Landing, refusing, and having nothing to do

    @Test func `a successful change reports its kind and action`() {
        let vm = viewModel(on: EditorFixtures.threeMeasuresOfQuarterRests(), targeting: 2)
        var reported: [(String, String)] = []
        vm.onSignatureChanged = { reported.append(($0, $1)) }
        #expect(vm.setTimeSignature(numerator: 3, denominator: 4))
        #expect(reported.map(\.0) == ["time"])
        #expect(reported.map(\.1) == ["set"])
        #expect(vm.lastSignatureRefusal == nil)
    }

    @Test func `a refused change surfaces the refusal and reports nothing`() {
        let vm = makeViewModel()
        vm.beginSession(score: Self.straddlingTriplet())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        var reported: [(String, String)] = []
        vm.onSignatureChanged = { reported.append(($0, $1)) }
        #expect(!vm.setTimeSignature(numerator: 3, denominator: 8))
        #expect(vm.lastSignatureRefusal?.reason == .rebarWouldSplitTuplet(measureIndex: 0))
        #expect(reported.isEmpty)
        #expect(vm.appliedEditCount == 0) // the intent was handed over, but nothing landed
    }

    @Test func `picking the key already in force is a quiet no-op, not a refusal`() {
        let vm = viewModel(on: EditorFixtures.threeMeasuresOfQuarterRests(), targeting: 2)
        var reported: [(String, String)] = []
        vm.onSignatureChanged = { reported.append(($0, $1)) }
        #expect(!vm.setKeySignature(concertKey: 0)) // the score is already in C major
        #expect(vm.lastSignatureRefusal == nil)
        #expect(reported.isEmpty)
    }

    @Test func `removing a change from a bar that declares none is a quiet no-op`() {
        let vm = viewModel(on: EditorFixtures.threeMeasuresOfQuarterRests(), targeting: 2)
        #expect(!vm.removeKeySignatureChange())
        #expect(!vm.removeTimeSignatureChange())
        #expect(vm.lastSignatureRefusal == nil)
    }

    @Test func `opening a sheet clears the refusal the last attempt left`() {
        let vm = makeViewModel()
        vm.beginSession(score: Self.straddlingTriplet())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        #expect(!vm.setTimeSignature(numerator: 3, denominator: 8))
        #expect(vm.lastSignatureRefusal != nil)
        vm.isTimeSignatureSheetPresented = true
        #expect(vm.lastSignatureRefusal == nil)
    }
}
