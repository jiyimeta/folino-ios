import SheetMusicCore

/// A rehearsal mark resolved to a position on the seek bar: its text, the fraction (0...1) of the notated timeline it
/// sits at, and the cursor to seek to when the user taps it.
struct ReaderRehearsalMark: Identifiable {
    let id: String
    let text: String
    let fraction: Double
    let cursor: ScoreCursor
}

extension Score {
    /// Rehearsal marks across the score, each placed on the seek bar by its tempo-weighted time fraction. Empty when
    /// the score has no marks or zero notated duration. Ordered by position.
    func rehearsalMarks() -> [ReaderRehearsalMark] {
        let total = notatedDurationSeconds
        guard total > 0 else { return [] }
        var marks: [ReaderRehearsalMark] = []
        for (measureIndex, systemMeasure) in systemMeasures.enumerated() {
            for positioned in systemMeasure.elements {
                guard case let .rehearsalMark(mark) = positioned.element else { continue }
                let tick = positioned.position.ticks(division: division)
                let cursor = ScoreCursor.beat(measureIndex: measureIndex, tickInMeasure: tick)
                let fraction = min(max(seconds(at: cursor) / total, 0), 1)
                marks.append(ReaderRehearsalMark(
                    id: "\(measureIndex)-\(tick)-\(mark.text)",
                    text: mark.text,
                    fraction: fraction,
                    cursor: cursor,
                ))
            }
        }
        return marks
    }
}
