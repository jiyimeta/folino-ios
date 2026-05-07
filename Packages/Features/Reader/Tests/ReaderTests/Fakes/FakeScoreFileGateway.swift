import Domain
import Foundation
import SheetMusicCore

// A 6-measure score fixture used by RepeatTests.
// Each measure has one voice with two quarter-note chords (index 0 and 1).
private func makeFixtureScore() -> Score {
    func measure() -> Measure {
        Measure(voices: [
            Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [])),
                .chord(Chord(duration: .quarter, notes: [])),
            ]),
        ])
    }
    let staff = Staff(measures: (0 ..< 6).map { _ in measure() })
    let part = Part(id: "P1", instrument: Instrument(id: "piano"), staves: [staff])
    return Score(division: 480, parts: [part])
}

final class FakeScoreFileGateway: ScoreFileGateway, @unchecked Sendable {
    var loadScoreResult: Result<(score: Score, summary: ScoreFileSummary), DomainError>

    init(loadScoreResult: Result<(score: Score, summary: ScoreFileSummary), DomainError> =
        .success((
            score: makeFixtureScore(),
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        )))
    {
        self.loadScoreResult = loadScoreResult
    }

    func detectFormat(fileName: String) -> ScoreFormat? { .mscx }

    func loadFileMetadata(fileURL: URL) throws -> ScoreFileSummary {
        throw DomainError.unsupportedFormat("test")
    }

    func loadScore(fileURL: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        switch loadScoreResult {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }

    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) throws {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}
