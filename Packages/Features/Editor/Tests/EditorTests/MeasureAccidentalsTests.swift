import Domain
@testable import Editor
import Foundation
import Testing

/// Key-signature-aware note input and the accidental glyphs that go with it. D major (`key: 2`) is the working
/// example throughout: F and C are sharp, so a letter key that lands on either has to write the ALTERED pitch, and
/// the glyphs have to say only what the reader can't already infer.
@MainActor
@Suite("Key signature aware input")
struct MeasureAccidentalsTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            playback: nil,
        )
    }

    /// The fixture's first writable slot: measure 0 opens with a key signature and a time signature.
    private static let firstRest = 2

    // MARK: - The key signature itself

    @Test func `a letter key writes the pitch the key signature spells`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: 2))
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest)))

        vm.inputPitch(letter: "c")

        let note = try #require(vm.score?[EditorFixtures.noteID(element: Self.firstRest)])
        #expect(note.pitch == 61)
        #expect(note.tpc == 21)
        // C♯ is what the signature already promises — printing a ♯ on it would be noise.
        #expect(note.accidental == nil)
    }

    @Test func `a letter key the signature doesn't touch stays natural`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: 2))
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest)))

        vm.inputPitch(letter: "d")

        let note = try #require(vm.score?[EditorFixtures.noteID(element: Self.firstRest)])
        #expect(note.pitch == 62)
        #expect(note.tpc == 16)
        #expect(note.accidental == nil)
    }

    @Test func `a flat key signature writes the flat`() throws {
        let vm = makeViewModel()
        // E♭ major: B, E, A flat.
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: -3))
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest)))

        vm.inputPitch(letter: "e")

        let note = try #require(vm.score?[EditorFixtures.noteID(element: Self.firstRest)])
        #expect(note.pitch == 63)
        #expect(note.tpc == 11)
        #expect(note.accidental == nil)
    }

    @Test func `writing over an existing note also follows the key signature`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: 2))
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest)))
        vm.inputPitch(letter: "d")
        // Back onto the note just written, and overwrite it.
        vm.select(.note(EditorFixtures.noteID(element: Self.firstRest)))

        vm.inputPitch(letter: "f")

        let note = try #require(vm.score?[EditorFixtures.noteID(element: Self.firstRest)])
        #expect(note.pitch == 66)
        #expect(note.tpc == 20)
    }

    // MARK: - Carrying an accidental forward inside the bar

    @Test func `a letter key inherits an accidental placed earlier in the same measure`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: 2))
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest)))
        vm.inputPitch(letter: "c")
        vm.setAccidental(.natural)

        vm.inputPitch(letter: "c")

        let first = try #require(vm.score?[EditorFixtures.noteID(element: Self.firstRest)])
        #expect(first.pitch == 60)
        // The first C♮ cancels the signature's C♯, so it needs the sign.
        #expect(first.accidental == .natural)

        let second = try #require(vm.score?[EditorFixtures.noteID(element: Self.firstRest + 1)])
        #expect(second.pitch == 60)
        #expect(second.tpc == 14)
        // The second is already covered by the first's ♮ — same sound, no second sign.
        #expect(second.accidental == nil)
    }

    @Test func `an accidental in one octave doesn't respell another`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: 2))
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest)))
        vm.inputPitch(letter: "c")
        vm.setAccidental(.natural) // C♮4 on beat 1
        let score = try #require(vm.score)

        // A C key whose octave search lands up by C5 — a different staff line from the C♮4 behind it.
        let planned = MeasureAccidentals.plannedPitch(
            forLetter: "c",
            nearestTo: 71,
            at: VoiceElementID(EditorFixtures.restID(element: Self.firstRest + 1)),
            in: score,
        )

        // The C4 natural never reached C5, so the signature's ♯ still rules there.
        #expect(planned?.pitch == 73)
        #expect(planned?.tpc == 21)
    }

    @Test func `an accidental does not carry across the barline`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: 2))
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest)))
        vm.inputPitch(letter: "c")
        vm.setAccidental(.natural)
        vm.select(.rest(EditorFixtures.restID(measure: 1, element: 0)))

        vm.inputPitch(letter: "c")

        let note = try #require(vm.score?[EditorFixtures.noteID(measure: 1, element: 0)])
        #expect(note.pitch == 61)
        #expect(note.tpc == 21)
    }

    // MARK: - Keeping the rest of the bar readable

    @Test func `changing a note gives the notes after it the accidentals they now need`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: 2))
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest)))
        vm.inputPitch(letter: "c") // C♯4, spelled by the signature — no glyph
        vm.inputPitch(letter: "c") // C♯4 again
        vm.select(.note(EditorFixtures.noteID(element: Self.firstRest)))

        vm.setAccidental(.natural)

        let second = try #require(vm.score?[EditorFixtures.noteID(element: Self.firstRest + 1)])
        #expect(second.pitch == 61)
        // The ♮ in front of it means this one can no longer rely on the signature — it has to say ♯ itself.
        #expect(second.accidental == .sharp)
    }

    @Test func `undo restores the accidentals the edit rewrote`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: 2))
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest)))
        vm.inputPitch(letter: "c")
        vm.inputPitch(letter: "c")
        vm.select(.note(EditorFixtures.noteID(element: Self.firstRest)))
        vm.setAccidental(.natural)

        vm.undo()

        let first = try #require(vm.score?[EditorFixtures.noteID(element: Self.firstRest)])
        let second = try #require(vm.score?[EditorFixtures.noteID(element: Self.firstRest + 1)])
        #expect(first.pitch == 61)
        #expect(first.accidental == nil)
        #expect(second.accidental == nil)
    }

    @Test func `a note tied over the barline keeps its accidental off the second bar`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: 2))
        vm.setDuration(.quarter)
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest + 3)))
        vm.inputPitch(letter: "c")
        vm.setAccidental(.natural) // C♮ on the last beat of bar 0
        vm.select(.note(EditorFixtures.noteID(element: Self.firstRest + 3)))

        vm.appendTiedNote()

        let continuation = try #require(vm.score?[EditorFixtures.noteID(measure: 1, element: 0)])
        #expect(continuation.pitch == 60)
        #expect(continuation.tieBack != nil)
        // Bar 1 starts over under the signature's C♯, so on its own this note would be handed a ♮. A tie already
        // carries the alteration across the barline — repeating it is exactly what MuseScore doesn't do.
        #expect(continuation.accidental == nil)
    }

    @Test func `a user-forced accidental survives renotation`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: 2))
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest)))
        vm.inputPitch(letter: "d")
        // A courtesy ♮ someone put on a D that never needed one, marked as theirs.
        let noteID = EditorFixtures.noteID(element: Self.firstRest)
        var score = try #require(vm.score)
        var note = try #require(score[noteID])
        note.accidental = .natural
        note.accidentalRole = .user
        score[VoiceElementID(noteID)] = .chord(Chord(duration: .quarter, notes: [note]))
        vm.beginSession(score: score)
        vm.select(.rest(EditorFixtures.restID(element: Self.firstRest + 1)))

        vm.inputPitch(letter: "e")

        let courtesy = try #require(vm.score?[noteID])
        #expect(courtesy.accidental == .natural)
    }
}
