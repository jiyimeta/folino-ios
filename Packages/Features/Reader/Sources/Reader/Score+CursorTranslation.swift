import SheetMusicCore

extension Score {
    /// When the engine emits a `.item(id)` cursor:
    ///
    /// * if the cursor's staff is hidden, translate to `.beat` so the
    ///   renderer falls back to interpolated X against the surviving
    ///   columns;
    /// * if the staff is visible but its full-score address differs
    ///   from its filtered address (an earlier staff in the same part
    ///   is hidden, or an earlier part is fully hidden), re-stamp the
    ///   `NoteID` / `RestID` with the filtered address so
    ///   `PlaybackCursorView.itemFrame`'s `LayoutDocument` lookup —
    ///   keyed by filtered addresses — can find it.
    ///
    /// `.beat` cursors and visible-staff `.item` values whose full and filtered addresses already match pass through
    /// unchanged.
    func translateCursorForHiddenStaves(
        _ cursor: ScoreCursor?,
        hiddenStaves hidden: Set<StaffAddress>,
    ) -> ScoreCursor? {
        guard let cursor else { return nil }
        guard !hidden.isEmpty,
              case let .item(id) = cursor
        else { return cursor }
        if hidden.contains(id.staff) {
            guard let tick = resolveTickInMeasure(for: id) else { return cursor }
            return .beat(measureIndex: id.measureIndex, tickInMeasure: tick)
        }
        guard let filteredStaff = filterStaffAddress(id.staff, hidingStaves: hidden),
              filteredStaff != id.staff
        else { return cursor }
        switch id {
        case let .note(noteID):
            return .item(.note(NoteID(
                staff: filteredStaff,
                measureIndex: noteID.measureIndex,
                voiceIndex: noteID.voiceIndex,
                elementIndex: noteID.elementIndex,
                noteIndexInChord: noteID.noteIndexInChord,
            )))
        case let .rest(restID):
            return .item(.rest(RestID(
                staff: filteredStaff,
                measureIndex: restID.measureIndex,
                voiceIndex: restID.voiceIndex,
                elementIndex: restID.elementIndex,
            )))
        case .tuplet, .clef:
            return cursor
        }
    }

    /// `nearestCursor` runs against a `LayoutDocument` built from the filtered score, so the `StaffAddress` it stamps
    /// onto `NoteID` / `RestID` is positional within the filtered parts. The playback engine's timeline is keyed by the
    /// full-score address, so the cursor has to be re-addressed before being handed to the controller — without it the
    /// engine fails to resolve the cursor (most visibly when the visible staff holds a whole rest and the hidden staff
    /// holds notes: the `.rest` key slot is occupied by the hidden staff's `.note` entries, so the lookup misses and
    /// `seek` silently no-ops). `.beat` cursors carry no staff address and pass through unchanged.
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
            // Tap-to-seek never produces these item kinds; pass through to keep the function total over `ScoreItemID`.
            return cursor
        }
    }
}
