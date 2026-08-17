import SheetMusicCore

/// A rehearsal mark resolved to a position on the seek bar, for SwiftUI consumption.
struct ReaderRehearsalMark: Identifiable {
    let id: String
    let text: String
    let fraction: Double
    let cursor: ScoreCursor
}

/// The seek card's score-derived inputs: the resolved rehearsal marks, the notated duration, and the per-measure
/// timing table the playhead is placed from.
///
/// Bundled so `ReaderViewModel` can cache them together, because every one of them walks the whole score:
/// `notatedDurationSeconds` re-derives the governing tempo for each measure (quadratic in measure count),
/// `rehearsalMarks()` repeats that walk once per mark, and `seconds(at:)` redoes it from the top for every position
/// it is asked about. That is far too expensive for the transport card's body — which runs on every frame of the
/// mode-swipe morph and on every finger movement while the card is being swiped — and, for `seconds(at:)`, far too
/// expensive to repeat on **every playback cursor tick**, which is what made a swipe stutter during playback.
///
/// Built once per score, the same walk answers all three, and placing the playhead afterwards is a table lookup.
struct ReaderSeekTimeline {
    static let empty = ReaderSeekTimeline(marks: [], measureTicks: [], measureSeconds: [])

    let marks: [ReaderRehearsalMark]
    /// Notated length of each measure in ticks and in seconds, and the elapsed seconds at each measure's downbeat.
    /// Parallel arrays over measure index — the shape `seconds(at:)` recomputes from scratch on every call.
    private let measureTicks: [Int]
    private let measureSeconds: [Double]
    private let measureStartSeconds: [Double]
    /// Total notated duration. Identical to `Score.notatedDurationSeconds` by construction: same per-measure formula,
    /// summed over the same measures.
    let durationSeconds: Double

    private init(marks: [ReaderRehearsalMark], measureTicks: [Int], measureSeconds: [Double]) {
        self.marks = marks
        self.measureTicks = measureTicks
        self.measureSeconds = measureSeconds
        var elapsed = 0.0
        var starts: [Double] = []
        starts.reserveCapacity(measureSeconds.count)
        for seconds in measureSeconds {
            starts.append(elapsed)
            elapsed += seconds
        }
        measureStartSeconds = starts
        durationSeconds = elapsed
    }

    /// One walk of the score, feeding the whole table. Mirrors `Score.notatedDurationSeconds`' own arithmetic — the
    /// measure's tick length, plus whatever its fermatas hold it for, at the quarter-BPM governing its downbeat — so
    /// the totals agree exactly. `ReaderSeekTimelineTests` pins that agreement against the engine's own API.
    init(score: Score) {
        let ticks = score.effectiveMeasureDurations().map { $0.ticks(division: score.division) }
        // A fermata adds no ticks to its bar but does add time to it. Bucket each hold's extra ticks onto its measure
        // so the bar's own tempo converts both parts the same way — leaving it out is what made the seek bar's total
        // (and every elapsed readout drawn from it) run short by the sum of every hold.
        var holdTicks = [Double](repeating: 0, count: ticks.count)
        for hold in score.fermataHolds() where holdTicks.indices.contains(hold.measureIndex) {
            holdTicks[hold.measureIndex] += hold.extraTicks
        }
        let seconds = ticks.enumerated().map { index, measureTicks -> Double in
            let bpm = max(1, score.effectiveQuarterBpm(at: .beat(measureIndex: index, tickInMeasure: 0)))
            let secondsPerTick = (60.0 / bpm) / Double(max(1, score.division))
            return (Double(measureTicks) + holdTicks[index]) * secondsPerTick
        }
        self.init(marks: score.readerRehearsalMarks(), measureTicks: ticks, measureSeconds: seconds)
    }

    /// Where a cursor sits on the seek bar, as a 0...1 fraction of the notated timeline.
    ///
    /// `tickInMeasure` is passed in rather than derived here: resolving it for an `.item` cursor means walking that
    /// one measure's voice, which only the score can do — but it is a single measure, not the whole score, so it is
    /// cheap enough to do per tick. Clamping matches `Score.seconds(at:)` so the thumb lands where the engine's own
    /// timing says it should.
    func fraction(measureIndex: Int, tickInMeasure: Int) -> Double {
        guard durationSeconds > 0, !measureTicks.isEmpty else { return 0 }
        let measure = min(max(measureIndex, 0), measureTicks.count - 1)
        var seconds = measureStartSeconds[measure]
        let ticks = measureTicks[measure]
        if ticks > 0 {
            let tick = min(max(tickInMeasure, 0), ticks)
            seconds += Double(tick) / Double(ticks) * measureSeconds[measure]
        }
        return min(max(seconds / durationSeconds, 0), 1)
    }
}

extension Score {
    /// Reader view-model wrapper over the shared `rehearsalMarks()` from SheetMusicCore.
    func readerRehearsalMarks() -> [ReaderRehearsalMark] {
        rehearsalMarks().enumerated().map { index, entry in
            ReaderRehearsalMark(
                id: "\(index)-\(entry.text)",
                text: entry.text,
                fraction: entry.fraction,
                cursor: entry.cursor,
            )
        }
    }
}
