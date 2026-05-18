import Domain
import SheetMusicCore

/// Returns the measure index the cursor points at. Both `ScoreCursor.beat` and `ScoreCursor.item` carry it directly:
/// `.beat` has it as a stored field, `.item(ScoreItemID)` exposes it via `ScoreItemID.measureIndex`.
func measureIndex(of cursor: ScoreCursor) -> Int {
    switch cursor {
    case let .beat(measureIndex, _): measureIndex
    case let .item(id): id.measureIndex
    }
}

/// First-chord ChordPath for the given measure (`voiceIndex = 0, chordIndex = 0`). The `systemIndex` is set to 0 — it's
/// a layout-side concept the engine doesn't consume here.
func snapMeasureHead(measureIndex: Int, in _: Score) -> ChordPath {
    ChordPath(systemIndex: 0, measureIndex: measureIndex, voiceIndex: 0, chordIndex: 0)
}

/// Last-chord ChordPath for the given measure. Walks voice 0 of the first staff to find the maximum chord index. Rests
/// are represented as `.chord(...)` with empty notes and count for this purpose; purely non-chord measures (only clef /
/// time signature / etc.) and empty voices return `nil`.
func snapMeasureEnd(measureIndex: Int, in score: Score) -> ChordPath? {
    guard let part = score.parts.first,
          let staff = part.staves.first,
          staff.measures.indices.contains(measureIndex) else { return nil }
    let voice = staff.measures[measureIndex].voices.first
    guard let elements = voice?.elements else { return nil }
    var lastChordIdx: Int?
    for (idx, element) in elements.enumerated() {
        if case .chord = element { lastChordIdx = idx }
    }
    guard let chordIndex = lastChordIdx else { return nil }
    return ChordPath(
        systemIndex: 0, measureIndex: measureIndex,
        voiceIndex: 0, chordIndex: chordIndex,
    )
}

/// Loop range covering the whole score, used for `.loopAll`. `nil` when the score has no measures.
func scoreFullRange(in score: Score) -> ABRepeatRange? {
    guard let part = score.parts.first,
          let staff = part.staves.first,
          !staff.measures.isEmpty else { return nil }
    let lastMeasure = staff.measures.count - 1
    let start = snapMeasureHead(measureIndex: 0, in: score)
    guard let end = snapMeasureEnd(measureIndex: lastMeasure, in: score) else { return nil }
    return ABRepeatRange(start: start, end: end)
}

/// Auto-swap so `start <= end` by `(measureIndex, chordIndex)`.
func normalize(_ range: ABRepeatRange) -> ABRepeatRange {
    let s = range.start
    let e = range.end
    let key: (ChordPath) -> (Int, Int) = { ($0.measureIndex, $0.chordIndex) }
    if key(s) <= key(e) { return range }
    return ABRepeatRange(start: e, end: s)
}
