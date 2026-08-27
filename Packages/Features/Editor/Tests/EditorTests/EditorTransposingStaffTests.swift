import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

/// The pad on a TRANSPOSING staff. The score is stored in concert pitch and drawn through `writtenPitchView()`, so
/// every key that names a note by letter — the pitch keys, the chord-arm letter, ♭/♯, the selection readout —
/// means the note on the page, not the note in the file.
///
/// The fixture is a B♭ clarinet in concert C major, which reads D major: written C is the key's own C♯, and it
/// sounds a concert B♮. Every assertion pairs the STORED concert pair with what `Score.writtenSpelling(of:)` says
/// the staff reads, because either one alone can be right while the other is wrong.
@MainActor
@Suite("Editor on a transposing staff")
struct EditorTransposingStaffTests {
    private func makeViewModel(playback: FakePlaybackController? = nil) -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: playback,
        )
    }

    /// The first rest of the fixture's only bar (after the key and time signatures).
    private static let slot = 2

    // MARK: - Letter keys

    @Test func `a letter key writes the letter the clarinet staff reads, stored as its concert pitch`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.clarinetQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: Self.slot)))

        vm.inputPitch(letter: "c")

        let noteID = EditorFixtures.noteID(element: Self.slot)
        let note = try #require(vm.score?[noteID])
        #expect(note.pitch == 59) // concert B♮3
        #expect(note.tpc == 19)

        let written = try #require(vm.score?.writtenSpelling(of: noteID))
        #expect(written.pitch == 61) // written C♯4 — D major's own C
        #expect(written.tpc == 21)
    }

    /// The old concert-space planning is the contrast: it wrote a concert C4, which this staff engraves as a D.
    @Test func `the concert spelling of the same letter would have engraved a D`() throws {
        let score = EditorFixtures.clarinetQuarterRests()
        let slot = VoiceElementID(EditorFixtures.restID(element: Self.slot))
        let concert = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "c", nearestTo: nil, at: slot, in: score,
        ))
        #expect(concert.pitch == 60)

        var wrong = score
        wrong[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: concert.pitch, tpc: concert.tpc)]))
        let written = try #require(wrong.writtenSpelling(of: EditorFixtures.noteID(element: Self.slot)))
        #expect(written.tpc == 16) // D, not the C the user typed
    }

    /// A letter over an existing note takes the `onNote` branch, and its reference pitch is the CONCERT pitch
    /// already in the slot — the planner converts it, so the octave search still runs against what is on the page.
    @Test func `a letter over an existing note plans from the written reference`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.clarinetQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: Self.slot)))
        vm.inputPitch(letter: "c")
        let noteID = EditorFixtures.noteID(element: Self.slot)
        vm.select(.note(noteID))

        vm.inputPitch(letter: "e")

        let note = try #require(vm.score?[noteID])
        #expect(note.pitch == 62) // concert D4
        #expect(note.tpc == 16)
        let written = try #require(vm.score?.writtenSpelling(of: noteID))
        #expect(written.pitch == 64) // written E4 — natural in D major
        #expect(written.tpc == 18)
    }

    /// The chord-arm branch is the third letter-name site and means the same thing the other two do.
    @Test func `the chord-arm letter stacks the note the staff reads`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.clarinetQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: Self.slot)))
        vm.inputPitch(letter: "c")
        vm.select(.note(EditorFixtures.noteID(element: Self.slot)))

        vm.toggleAddToChord()
        vm.inputPitch(letter: "e")

        guard case let .chord(chord)? = vm.score?[VoiceElementID(EditorFixtures.noteID(element: Self.slot))] else {
            Issue.record("expected a chord")
            return
        }
        #expect(chord.notes.map(\.pitch) == [59, 62]) // concert B♮3 + D4
        let upper = try #require(vm.score?.writtenSpelling(
            of: EditorFixtures.noteID(element: Self.slot, noteIndex: 1),
        ))
        #expect(upper.tpc == 18) // written E
    }

    // MARK: - Accidental keys

    /// ♭ means "flatten the note on the page". Written C♯4 flattened is written C♭4, which sounds a concert B♭♭3.
    /// Respelling the CONCERT note instead preserved the letter B and produced a concert B♭3 — written C natural,
    /// i.e. the user pressed ♭ and watched the sharp turn into a natural.
    @Test func `flat respells the written letter, not the concert one`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.clarinetQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: Self.slot)))
        vm.inputPitch(letter: "c")
        let noteID = EditorFixtures.noteID(element: Self.slot)
        vm.select(.note(noteID))

        vm.setAccidental(.flat)

        let note = try #require(vm.score?[noteID])
        #expect(note.pitch == 57) // concert B♭♭3
        #expect(note.tpc == 5)
        let written = try #require(vm.score?.writtenSpelling(of: noteID))
        #expect(written.pitch == 59) // written C♭4
        #expect(written.tpc == 7)
    }

    // MARK: - The relative keys, which need no conversion

    /// ▴ shifts in concert space and still lands on the written spelling — MuseScore's rule compares the note's
    /// tpc against the key's, and the written view moves both by the same amount. `WrittenInputTests` in ssm
    /// carries the general proof; this is the pad-level guard on it.
    @Test func `a semitone shift lands on the written spelling without any conversion`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.clarinetQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: Self.slot)))
        vm.inputPitch(letter: "c")
        let noteID = EditorFixtures.noteID(element: Self.slot)
        vm.select(.note(noteID))

        vm.shiftPitch(bySemitones: 1)

        let note = try #require(vm.score?[noteID])
        #expect(note.pitch == 60) // concert C4
        #expect(note.tpc == 14)
        let written = try #require(vm.score?.writtenSpelling(of: noteID))
        #expect(written.pitch == 62) // written D4 — C♯ resolved diatonically upward in D major
        #expect(written.tpc == 16)
    }

    @Test func `an octave shift is transposition-invariant`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.clarinetQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: Self.slot)))
        vm.inputPitch(letter: "c")
        let noteID = EditorFixtures.noteID(element: Self.slot)
        vm.select(.note(noteID))

        vm.shiftOctave(by: 1)

        let written = try #require(vm.score?.writtenSpelling(of: noteID))
        #expect(written.pitch == 73) // still a written C♯, an octave up
        #expect(written.tpc == 21)
    }

    // MARK: - Readout and audition

    @Test func `the readout names the written note`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.clarinetQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: Self.slot)))
        vm.inputPitch(letter: "c")

        let score = try #require(vm.score)
        let noteID = EditorFixtures.noteID(element: Self.slot)
        #expect(NoteNameFormatter.name(of: noteID, in: score) == "C♯4")
        #expect(NoteNameFormatter.readout(for: .note(noteID), in: score).hasPrefix("C♯4 · "))
    }

    /// Audition sounds the CONCERT pitch, because it is handed `vm.score` — the stored score, which the written
    /// view never touches. A B♭ clarinet playing its written C has to sound a B♭ (here a B♮, since the letter
    /// resolved to the key's C♯), or the preview would disagree with playback.
    @Test func `the preview sounds the concert pitch`() async {
        let fake = FakePlaybackController()
        let vm = makeViewModel(playback: fake)
        vm.beginSession(score: EditorFixtures.clarinetQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: Self.slot)))

        vm.inputPitch(letter: "c")
        await vm.auditionTask?.value

        let noteID = EditorFixtures.noteID(element: Self.slot)
        #expect(fake.recordedScorePreviewCalls.map(\.noteID) == [noteID])
        #expect(vm.score?[noteID]?.pitch == 59)
    }

    // MARK: - Nothing changes on a concert-pitch staff

    @Test func `a concert-pitch staff is untouched by the written-space routing`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests(key: 0))
        vm.select(.rest(EditorFixtures.restID(element: Self.slot)))

        vm.inputPitch(letter: "c")

        let noteID = EditorFixtures.noteID(element: Self.slot)
        let note = try #require(vm.score?[noteID])
        #expect(note.pitch == 60)
        #expect(note.tpc == 14)
        let written = try #require(vm.score?.writtenSpelling(of: noteID))
        #expect(written.pitch == 60)
        #expect(written.tpc == 14)
    }
}
