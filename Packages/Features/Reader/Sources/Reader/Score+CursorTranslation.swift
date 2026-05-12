import SheetMusicCore

extension Score {
    /// When the engine emits a `.item(id)` cursor whose staff is hidden,
    /// the rendering side (`PlaybackCursorView.itemFrame`) can't resolve
    /// it because `LayoutDocument` was built from a filtered Score.
    /// Translate to `.beat` so the cursor falls back to interpolated X
    /// against the surviving columns. `.beat` and visible-staff `.item`
    /// values pass through unchanged.
    func translateCursorForHiddenStaves(
        _ cursor: ScoreCursor?,
        hiddenStaves hidden: Set<StaffAddress>,
    ) -> ScoreCursor? {
        guard let cursor else { return nil }
        guard !hidden.isEmpty,
              case let .item(id) = cursor,
              hidden.contains(id.staff),
              let tick = resolveTickInMeasure(for: id)
        else { return cursor }
        return .beat(measureIndex: id.measureIndex, tickInMeasure: tick)
    }

    /// `nearestCursor` runs against a `LayoutDocument` built from the
    /// filtered score, so the `StaffAddress` it stamps onto `NoteID` /
    /// `RestID` is positional within the filtered parts. The playback
    /// engine's timeline is keyed by the full-score address, so the
    /// cursor has to be re-addressed before being handed to the
    /// controller — without it the engine fails to resolve the cursor
    /// (most visibly when the visible staff holds a whole rest and the
    /// hidden staff holds notes: the `.rest` key slot is occupied by
    /// the hidden staff's `.note` entries, so the lookup misses and
    /// `seek` silently no-ops). `.beat` cursors carry no staff address
    /// and pass through unchanged.
    func engineCursorForFilteredTap(
        _ cursor: ScoreCursor,
        hiddenStaves hidden: Set<StaffAddress>,
    ) -> ScoreCursor {
        guard !hidden.isEmpty,
              case let .item(id) = cursor,
              let full = unfilterStaffAddress(id.staff, hidingStaves: hidden)
        else { return cursor }
        switch id {
        case let .note(noteID):
            return .item(.note(NoteID(
                staff: full,
                measureIndex: noteID.measureIndex,
                voiceIndex: noteID.voiceIndex,
                elementIndex: noteID.elementIndex,
                noteIndexInChord: noteID.noteIndexInChord,
            )))
        case let .rest(restID):
            return .item(.rest(RestID(
                staff: full,
                measureIndex: restID.measureIndex,
                voiceIndex: restID.voiceIndex,
                elementIndex: restID.elementIndex,
            )))
        case .tuplet, .clef:
            // Tap-to-seek never produces these item kinds; pass
            // through to keep the function total over `ScoreItemID`.
            return cursor
        }
    }
}
