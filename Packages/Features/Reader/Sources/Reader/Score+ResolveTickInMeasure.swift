import SheetMusicCore

extension Score {
    /// In-measure tick offset of the voice element identified by `itemID`, summing chord/rest durations in the voice up
    /// to (not including) `itemID.elementIndex`. Returns `nil` when the path doesn't resolve.
    ///
    /// Used to translate a `.item(id)` cursor anchored on a hidden-staff element into a
    /// `.beat(measureIndex:tickInMeasure:)` cursor that `PlaybackCursorView` can interpolate against the visible
    /// staves.
    func resolveTickInMeasure(for itemID: ScoreItemID) -> Int? {
        guard let staff = self[itemID.staff] else { return nil }
        guard staff.measures.indices.contains(itemID.measureIndex) else { return nil }
        let voices = staff.measures[itemID.measureIndex].voices
        guard voices.indices.contains(itemID.voiceIndex) else { return nil }
        let elements = voices[itemID.voiceIndex].elements
        guard itemID.elementIndex >= 0,
              itemID.elementIndex <= elements.count
        else { return nil }

        var tick = 0
        for i in 0 ..< itemID.elementIndex {
            if case let .chord(chord) = elements[i] {
                tick += chord.duration.ticks(division: division)
            }
        }
        return tick
    }

    /// In-measure tick offset of a cursor regardless of its `.item` vs `.beat` flavour. `.beat` carries the tick
    /// directly; `.item` resolves it by walking the voice (returns 0 when the path doesn't resolve). Used by the
    /// measure-step transport to decide whether a "back" press rewinds to the previous measure or restarts the current
    /// one.
    func tickInMeasure(of cursor: ScoreCursor) -> Int {
        switch cursor {
        case let .beat(_, tick): tick
        case let .item(id): resolveTickInMeasure(for: id) ?? 0
        }
    }

    /// Tick length of one notated beat (the prevailing time-signature denominator unit) in the measure at
    /// `measureIndex`. Carries the time signature forward from earlier measures, defaulting to 4/4. Returns `nil` when
    /// the measure index is out of range. The denominator is read from the unreduced `TimeSignature` (not the measure's
    /// reduced duration `Fraction`), so 4/4 yields a quarter-note beat and 6/8 an eighth-note beat.
    func beatTicks(atMeasure measureIndex: Int) -> Int? {
        guard let measures = parts.first?.staves.first?.measures,
              measures.indices.contains(measureIndex)
        else { return nil }
        var denominator = 4
        for i in 0 ... measureIndex {
            for case let .timeSignature(ts) in measures[i].voices.flatMap(\.elements) {
                denominator = ts.denominator
                break
            }
        }
        return 4 * division / denominator
    }
}
