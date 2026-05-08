import SheetMusicCore

extension Score {
    /// In-measure tick offset of the voice element identified by `itemID`,
    /// summing chord/rest durations in the voice up to (not including)
    /// `itemID.elementIndex`. Returns `nil` when the path doesn't resolve.
    ///
    /// Used to translate a `.item(id)` cursor anchored on a hidden-staff
    /// element into a `.beat(measureIndex:tickInMeasure:)` cursor that
    /// `PlaybackCursorView` can interpolate against the visible staves.
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
}
