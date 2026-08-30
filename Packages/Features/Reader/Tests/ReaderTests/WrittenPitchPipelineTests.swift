import Domain
import Foundation
@testable import Reader
import Testing

/// A transposing part must be ENGRAVED at written pitch while everything downstream of the display pipeline —
/// playback, MIDI export, save — keeps reading the concert score. These tests pin the display side: the score the
/// Reader hands its containers is the written-pitch view, and `loadState.score` (what the sequencer is loaded from)
/// is not.
@MainActor
@Suite("Written-pitch display pipeline")
struct WrittenPitchPipelineTests {
    // MARK: - Fixture

    /// Part 0 flute (concert), part 1 B♭ clarinet — one G staff each, C major 4/4, one whole note at concert B♭4.
    ///
    /// Built from model values rather than `Score.blank` on purpose: the blank-score template API is still moving,
    /// and this test is about the display pipeline, not about how a blank score is spelled.
    private func ensemble() -> Score {
        let voice = Voice(elements: [
            .keySignature(KeySignature(concertKey: 0)),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .whole, notes: [Note(pitch: 70, tpc: 12)])),
        ])
        let staff = Staff(defaultClefType: "G", measures: [Measure(voices: [voice])])
        return Score(
            division: 480,
            parts: [
                Part(id: "1", instrument: Instrument(id: "flute"), staves: [staff]),
                Part(
                    id: "2",
                    instrument: Instrument(id: "clarinet", transposeDiatonic: -1, transposeChromatic: -2),
                    staves: [staff],
                ),
            ],
        )
    }

    private func firstNote(_ score: Score, part: Int) -> Note? {
        guard case let .chord(chord) = score.parts[part].staves[0].measures[0].voices[0].elements[2]
        else { return nil }
        return chord.notes.first
    }

    private func openingKey(_ score: Score, part: Int) -> Int? {
        guard case let .keySignature(key) = score.parts[part].staves[0].measures[0].voices[0].elements[0]
        else { return nil }
        return key.concertKey
    }

    private func makeViewModel() -> ReaderViewModel {
        ReaderViewModel(
            scoreItem: PreviewFakeRepository.sampleItem,
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            scoresDirectory: FileManager.default.temporaryDirectory,
            playbackController: FakePlaybackController(),
        )
    }

    // MARK: - Tests

    /// `visibleScore` is what the score containers engrave, so the clarinet has to read as written C5 (pitch 72,
    /// tpc 14) in D major there — while `loadState.score`, the score the audio engine and every save path read,
    /// still holds the concert B♭4 it was given.
    @Test
    func `visibleScore is written pitch while the source score stays concert`() async throws {
        let viewModel = makeViewModel()
        await viewModel.adoptEditedScore(ensemble())

        let visible = try #require(viewModel.visibleScore)
        #expect(firstNote(visible, part: 0)?.pitch == 70) // flute: concert part, untouched
        #expect(firstNote(visible, part: 0)?.tpc == 12)
        #expect(openingKey(visible, part: 0) == 0)

        #expect(firstNote(visible, part: 1)?.pitch == 72) // clarinet: concert B♭4 written as C5
        #expect(firstNote(visible, part: 1)?.tpc == 14)
        #expect(openingKey(visible, part: 1) == 2) // C major sounding → D major written

        // The display transform must never reach the score playback / export / save read from.
        let source = try #require(viewModel.loadState.score)
        #expect(firstNote(source, part: 1)?.pitch == 70)
        #expect(openingKey(source, part: 1) == 0)
    }

    /// The shared chain at the two arguments the Reader actually passes: the reading / PiP path (a live global
    /// transpose) and the editing path (transpose pinned to 0). Both must still apply the written view, and the
    /// two shifts must compose rather than one replacing the other.
    @Test
    func `the display chain applies the written view with and without a global transpose`() {
        let concert = ensemble()

        let editing = ReaderDisplayTransforms.display(
            concert, clefOverrides: [:], transposeSemitones: 0, hiddenStaves: [],
        )
        #expect(firstNote(editing, part: 1)?.pitch == 72)
        #expect(openingKey(editing, part: 1) == 2)

        // +2 semitones on top of the written view: written C5 → D5, D major → E major.
        let transposed = ReaderDisplayTransforms.display(
            concert, clefOverrides: [:], transposeSemitones: 2, hiddenStaves: [],
        )
        #expect(firstNote(transposed, part: 1)?.pitch == 74)
        #expect(openingKey(transposed, part: 1) == 4)
        #expect(firstNote(transposed, part: 0)?.pitch == 72) // flute moves by the global transpose only
        #expect(openingKey(transposed, part: 0) == 2)

        // Hidden staves renumber last, after the written view has already run against full-score addresses.
        let filtered = ReaderDisplayTransforms.display(
            concert,
            clefOverrides: [:],
            transposeSemitones: 0,
            hiddenStaves: [StaffAddress(partIndex: 0, staffIndexInPart: 0)],
        )
        #expect(filtered.parts.count == 1)
        #expect(firstNote(filtered, part: 0)?.pitch == 72)
    }

    /// PiP engraves the same page the reader does, from a snapshot of the same inputs.
    @Test
    func `the PiP arm score is the written-pitch view`() {
        let snapshot = PiPLayoutSnapshot(
            staffSize: 7, hiddenStaves: [], clefOverrides: [:], transposeSemitones: 0,
        )
        let armed = ReaderPiPSession.armScore(ensemble(), snapshot: snapshot)
        #expect(firstNote(armed, part: 1)?.pitch == 72)
        #expect(openingKey(armed, part: 1) == 2)
    }
}
